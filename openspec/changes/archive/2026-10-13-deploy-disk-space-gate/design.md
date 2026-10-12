# Design: Disk-space gate for direct deploy

## Context

Live deploy flow today (`_liveApply` in `.forgejo/actions/deploy-target/action.yml`):
build toplevel → `nix copy --to ssh://<deploy-user>@<host>` → pointer file →
`systemctl start nixtache-apply.service`. The gated SSH channel
(`modules/deploy-target/user.nix`) whitelists exactly: `true`,
`nix-store --serve ...`, the two pointer+trigger forms, and the ab triggers.
The apply unit (`apply.nix`) sets the profile, switches, probes
`criticalUnits`, rolls back on failure. Consumer run 708 showed the gap: a
full-disk target accepts the copy, then dies mid-activation on ENOSPC.
Precedent for space gating: `ab-provision.nix` (free bytes vs 2 × slot
size). Runner job env has no `HOME`, so every action ssh call emits
`/.ssh` warnings and pins nothing.

## Goals / Non-Goals

- Goals: fail a space-starved deploy before data movement (runner side) and
  before profile mutation (target side); keep the check read-only through
  the gate; make action ssh HOME-independent.
- Non-Goals: ab-image path (already gates); target-side retention policy
  (consumer repo); provisioning target host keys into the runner config.

## Decisions

### D1: Need estimation = missing-paths delta + preset, conservative fallback

`nix copy` has no dry-run (verified). The check runs TWICE per target around
one `df` round-trip (queried once, pre-build):

1. **Pre-build fast refuse**: `avail < preset` → per-target error, no build,
   no copy — nearly-full devices are skipped in seconds.
2. **Post-build sized check**: need = Σ narSize(missing) × 1.1 + preset.
   Missing is computed from `nix path-info --store ssh://<user>@<host>
   --all` (remote inventory) diffed against the local `nix path-info -r -S
   $P` closure listing — text formats, not `--json` (deprecated without
   `--json-format` in nix 2.34; shape differs across versions). Fallback
   when the inventory query fails: need = full closure size (`nix path-info
   -s $P`) × 1.1 + preset. A conservative refusal is safe (the nightly
   consumer `autoUpgrade` builds on-target and only needs the delta), while
   a delta-unaware refusal on a half-full disk would falsely block routine
   deploys. Alternatives rejected: fixed per-target `minFree` alone (no
   relation to actual closure size); per-path remote existence probes (N
   round-trips).

### D2: On insufficient space — error the target, continue the job

The per-target step records `::error::<cfg>: target <host> low on disk
(<avail> B free, <need> B needed)` and moves on; the job fails at the end if
any target errored. This failure policy applies to ALL per-target deploy
failures (low disk, copy/apply errors, timeouts, both methods) — one bad
target must not starve the rest of the loop. Alternatives rejected: `exit 1`
in place (the pre-change behavior); skip-with-warning like unreachable hosts
(a machine that is up but undeployable deserves a red signal, not a
footnote; contrast D6 — a target we cannot *assess* is a different class).

### D3: Gate command = exact-match `df` on the store mount

The gate whitelist gains the literal string
`df -B1 --output=avail /nix/store` — byte output, single line, no
redirection, trivially regex-safe. The action parses the last line as an
integer. Mutated forms fall through to the standard rejection path.
Alternative `stat -f -c %a` (terser but less familiar) rejected; `df` is in
every target's base profile.

### D4: `minFreeBytes` option on the apply unit only — unsigned, 0 disables

`services.nixtache.deploy-target.minFreeBytes` (types.ints.unsigned, bytes,
default 5 GiB). `nixtache-apply.service` checks it before `nix-env --set`:
below threshold → consume pointer, exit 1 with a garbage-collection hint,
profile untouched (spec: nothing activated, no rollback runs). `0` disables
the guard entirely (consumer escape valve). The dry-apply unit is exempt
(dry-activate mutates nothing). Precedent: ab-provision's `free_bytes` gate.

### D5: `UserKnownHostsFile` pinned per job workspace

All action ssh invocations (probe, copy via `NIX_SSHOPTS`, triggers) add
`-o UserKnownHostsFile=$PWD/.deploy-known-hosts`. Removes the `HOME`
dependency; host keys persist across the job's connections (all targets,
probe + copy + trigger) so TOFU happens once per job per host. /dev/null
alternative (zero persistence, warning per connection) rejected as noisier
and weaker. Feeding pinned keys via the runner module's known-hosts
machinery is a future option, out of scope.

### D6: Protocol drift = per-target warning + skip, never a red job

A new action against a still-old gate gets its free-space query rejected;
an unparseable answer is the same class. That is a *transition* condition,
not a target failure: the per-target step returns a distinct code, the loop
emits `::warning::<cfg>: … skipped (transition: sshGate="restrict" …)` and
the job stays green if drift is the only anomaly (contrast D2: genuinely
failing targets stay red — one bad target must not starve the loop, but a
deploying job must not be held hostage by a lagging one either). Upgrade
order remains two-phase: (1) ship module changes (gate entry +
minFreeBytes) — consumer deploys targets with the current action; (2) ship
the action change. Escape hatch: `sshGate = "restrict"` on a lagging target
(migration.md §5). `_liveApply` logic stays embedded in action.yml (the
ab-image VM-test parsing precedent — do not extract to a script).

### D7: Twin `minFreeBytes` knobs, one per side

The preset lives on BOTH sides, each configurable, both defaulting to
5 GiB, `0` disabling on each side:

- runner side: `services.nixtache.runner.deploy.targets.<name>.minFreeBytes`
  — drives the two-stage pre-copy check (D1); `0` skips the check entirely
  (no `df` query issued — also a rollout nicety for old gates);
- target side: `services.nixtache.deploy-target.minFreeBytes` — the
  apply-unit guard (D4).

They are independent on purpose (the runner cannot read the target's module
config), with docs advising runner-side ≥ target-side. This resolves the
formerly deferred open question of a runner-side per-target floor.

## Risks / Trade-offs

- [`--all` inventory is heavy on very large stores] → single streamed ssh
  round-trip, parsed incrementally; fallback path (D1) keeps deploys
  working when it is unavailable.
- [Drift skip masks a lagging target forever] → the per-target
  `::warning::` is emitted on every run; the consumer migration guide
  (§5) prescribes the two-phase order and the `restrict` hatch.
- [Apply-unit guard effective only after a target's next successful deploy]
  → the unit that runs is the active generation's; D6 phase 1 carries it;
  runner-side D1 protects the transition window.
- [minFreeBytes too low on single-fs machines (root full for non-nix
  reasons)] → the guard is about activation headroom; consumer retention
  policy (their repo) handles the rest.

## Migration Plan

1. nixtache: module changes + tests + docs (deploy.md, technical details,
   migration.md note) — tag/release.
2. Consumer: bump nixtache, deploy desktop/laptop (phase 1), then the
   action change activates phase 2 on the next run.
3. Rollback: revert the action (phase 2 invisible to targets); module
   revert via a normal deploy.

## Open Questions

- None. (The runner-side per-target floor — formerly deferred — landed as
  D7.)

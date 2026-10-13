# Design

## Context

See `proposal.md` → Why for motivation. The facts that shape the approach:

**Overlay store internals (verified against Nix 2.34.8 source — the version
the appliance's nixpkgs ships).** The `local-overlay-store` design intends
ONE SQLite DB (`/nix/var/nix/db`, on the writable root) covering BOTH
layers: `isValidPathUncached` falls through to the lower store and, on a
hit, registers the path info and recursively syncs its closure; the upper
layer is meant to hold only the delta (GC/optimise delete upper copies of
lower-valid paths — via the upperdir directly, to avoid OverlayFS
whiteouts — and demand a `remount-hook` afterwards). Store verification
(`nix-store --verify`) checks DB entries against the MERGED view: entries
whose files vanished are auto-invalidated when no valid referrer remains,
and `--repair` re-fetches missing references of still-valid paths from
substituters.

**The three lower-DB worlds.** (A) upstream-intended: lower store has its
own DB → upper is a delta → an OTA swap dangles upper refs (the hazard).
(B) nixtache appliance today: `lower-store=local` shares the one DB → the
lower fall-through is a no-op → `nix-store --realize` pulls FULL closures
into the upper → the upper survives swaps by accident of closure
completeness. (C) the `overlay-nix-install-vm` test world: lower = host
store WITH a DB → world-A semantics inside the harness. World C test
results do NOT transfer to world B appliances; tests must name their world.

**Today's residual hazards on world B.** GC takes the dedup branch (lower
validity reads the same DB) and warns "needs remounting" — the module sets
no `remount-hook`. Lower (system) paths are invisible to nix operations:
realizing one duplicates it into the upper, or fails without a substituter.
Upper + DB grow unboundedly across generations. World A becomes reachable
via manual registration, a future image-shipped lower DB (the upstream
endgame), or broken closures.

**Seeding fact (empirically proven on 2.34.8).** `nix-store --load-db`
registers validity from a 5-line-per-path text record (path, bare-base16
narHash, narSize, deriver-or-empty, ref-count + refs) with ZERO file
access; `--register-validity` MUST NOT be used for this — it canonicalises
metadata, chmod-ing through the merged view, which makes OverlayFS copy
the lower files up and destroys the lower-only premise.

**OTA route today.** All three update triggers are nixtache-owned (action
SSH `systemctl start systemd-sysupdate`, idle-gated `nixtache-ab-apply`,
auto-update poll); systemd-sysupdate has no native pre/post hooks. The
e2e harness pattern (extract the real action.yml `run:` text at build
time, fake-nix boundary, real GPT) is proven twice (`ab-ota-e2e`,
`ab-deploy`). No vmTests suite runs in CI (nspawn runner, no KVM); the
runner module already propagates host `nix.settings.system-features` into
the container.

## Goals / Non-Goals

**Goals:**

- Pin overlay×OTA semantics empirically (the replication suite is a
  research deliverable, not just a regression net) for every branch of the
  spec matrix.
- Lifecycle option wired into ALL trigger paths with one attachment point.
- GC coherence (`remount-hook`) and dangling-ref observability (verify).
- Close the five e2e gaps with the existing harness pattern.
- vmTests in CI on a KVM runner; deployment prerequisites documented.

**Non-Goals:**

- Shipping a lower store DB inside appliance images (the upstream-aligned
  endgame). The reconcile mode is designed to be exactly what that future
  needs — but building/baking the DB is out of scope.
- Version-keyed upper directories (a fourth lifecycle mode candidate) —
  the enum leaves room; not designed now.
- Changing sysupdate transfer semantics, the live deploy path, or runner
  container store modes.
- Healing without a substituter: reconcile's repair leg requires one by
  design; the degraded branch reports instead of inventing sources.
- A CI lint that no live doc references migration.md (manual sweep only;
  revisit later).

## Decisions

### D1: `upperOnUpdate` is a three-value enum, default `"none"`

`"none" | "wipe" | "reconcile"` under
`services.nixtache.overlay-nix.upperOnUpdate`. Rationale: the policies are
three distinct observable behaviours, and `"none"` (today's behaviour) must
remain expressible as a DEFAULT so nothing breaks on module bump. A bool
(the initial instinct) cannot distinguish "no policy" from either policy; a
future `"versioned"` mode (per-image-version upper dirs) slots in without
migration. Alternative rejected: two boolean options — invalid
combinations, worse docs.

### D2: Reconcile engine = verify (detection) + per-root closure repair (delta fetch)

The post-boot reconcile pass runs, in order:

1. `nix-store --verify` — auto-invalidates DB entries whose files are gone
   from the merged view and that nothing valid refers to. Its exit code is
   advisory: referrer-protected danglers are deliberately left valid and
   can even trip a harmless SQLite FOREIGN KEY message during the
   invalidation attempt (observed on Nix 2.34.8 — `validPaths` in
   `verifyPath` does not count paths fixed by repair, so a protected
   dangler can take the invalidate branch and bounce off the FK; the row
   survives, which is the desired outcome).
2. Per-root closure repair: for every recorded root (gc-roots + profile
   link targets, captured pre-update), walk `nix-store -q --requisites`
   and `nix-store --repair-path` exactly the paths whose files are absent
   from the merged store — a delta repair (a rooted `pkgs_2` whose
   `pkgs_1` dep dangled heals by fetching `pkgs_1` alone; present paths
   are not touched; the walk also heals build-time-only danglers the
   global verify cannot invalidate).

An earlier draft used the global `nix-store --verify --repair` for step 2;
the replication suite showed it heals the critical paths but exits
nonzero on the FK noise above, which would keep healthy reconcile runs
permanently red — hence the per-root walk, whose failure set is exactly
"paths the substituter cannot serve". The "reinstall the list" idea from
the exploration survives as the profile-link targets inside roots.txt
(realizing a profile's store path restores all its entries in one shot —
no manifest parsing). Rationale vs blanket re-install: strictly less
network work and it heals rooted closures precisely.

**Why per-path, contractually (not just empirically).** There is no
specification of verify/repair beyond four layers, and only one of them
is formal:

1. **man pages** — three sentences per command: verify checks DB↔store
   consistency and "inconsistencies are automatically repaired";
   `--repair` redownloads missing/modified paths; `repair-path`
   redownloads from substituters, with the single formally documented
   caveat being the non-atomic replace window. The exit codes of
   `nix-store --verify` are not documented at all (the new
   `nix store verify` documents 1/2/4 — but for content/signature
   checks, not DB coherence).
2. **`src/libstore/schema.sql`** — the only FORMAL contract:
   `Refs.reference → ValidPaths ON DELETE RESTRICT` (a referenced path
   cannot be invalidated), `referrer → CASCADE`, plus the
   `DeleteSelfRefs` trigger with an explanatory comment.
3. **Functional tests** (`tests/functional/local-overlay-store/verify-inner.sh`)
   — the executable spec, pinning literal message strings via grep for
   exactly ONE shape: a lower-removed path whose referrers still have
   their files (`"disappeared, but it still has valid referrers!"` +
   repair refetches), modified contents, and a lower-only path absent
   from the DB. The shape our suite constructs (referrer chain where an
   intermediate referrer is itself a kept files-missing valid path) is
   NOT covered — it lives in the unspecified zone.
4. **The C++ `verifyPath`** — the de-facto spec for everything else,
   including the `validPaths` bookkeeping that causes the FK noise: the
   algorithm treats "valid referrer" as "in `validPaths`" (files
   present), a kept dangling referrer does not qualify, and the
   attempted delete bounces off the schema's RESTRICT. The schema
   enforces the invariant the algorithm miscounts — the row survives
   (safe outcome), but messages and exit codes are
   implementation-defined.

This failure class is neither new nor overlay-specific: NixOS/nix#9285
(Nov 2023, plain local store, Nix 2.17) shows the identical message
triangle ending in the same FOREIGN KEY error, and a 2015 Guix commit
records the same constraint failure during `--verify-path`. As for
alternative implementations: snix (ex-tvix) calls the nix-daemon
protocol "entirely custom and undocumented" and implements only the
READ-ONLY LOWER side of the overlay store; Lix shares the C++ lineage —
so no cross-implementation contract for the upper side exists to port.
The portable pieces are the schema invariants and the test-pinned
strings, nothing more.

Conclusion for the engine: the only behaviour standing on a genuinely
specified contract is the per-path one — a store path is
content-addressed, so "ensure this path exists with the right hash,
else refetch" is deterministic, compositional (a closure is a
composition of per-path ensures) and has an exact failure set. The
global `verify --repair` is a graph heuristic that lives only in the C++
implementation. The reconcile pass therefore uses step 1 solely as
best-effort detection/auto-invalidation (never trusting its exit code)
and performs ALL healing per-path.

### D3: Hook attachment = drop-in on `systemd-sysupdate.service`

The module installs `nixtache-overlay-preupdate.service` (oneshot,
`Before=systemd-sysupdate.service`, pulled in via a sysupdate drop-in
`Wants=`) which, per mode: `"wipe"` — clears upper + work + the overlay
DB state (see D4); `"reconcile"` — records the capture set (profile
manifests via `nix profile list --json`, gc-roots enumeration) to
`/var/lib/nixtache/overlay-capture/` on the persistent root and drops the
reconcile marker. `nixtache-overlay-reconcile.service` runs next boot
(`After=` overlay mount + nix-daemon, `WantedBy=multi-user.target`,
`ConditionPathExists=` marker), executes D2, and consumes the marker only
on success (degraded runs keep it red for visibility; a later boot or
manual restart retries).

Why one drop-in instead of editing each trigger unit: a single attachment
point covers the action SSH trigger, the gating `nixtache-ab-apply` path,
the auto-update poll AND sysupdate's own timer identically — and stays
correct when new trigger paths appear.

### D4: Wipe semantics

Wipe runs at the pre-update instant: stop `nix-daemon.service` (the socket
survives), remove upper-layer contents + work dir contents + the overlay
DB state files under `/nix/var/nix/` (on an appliance these are
overlay-created state only — the system itself boots from the squashFS
lower and carries no system profiles there), then start the daemon again.
The restart matters for the no-op case: sysupdate may find nothing new and
the machine must keep working without a reboot. A realize racing the wipe
loses its progress (both files and DB entries vanish together — coherent);
acceptable at a deliberate update boundary, documented in the option
description.

### D5: `remount-hook` = full unmount + remount of the overlay

The module sets `nix.settings.remount-hook` to a small script that
unmounts and re-mounts the overlay at `/nix/store` with the same options
(retrying on EBUSY). The hook fires after GC's dedup-branch deletions
(direct upperdir manipulation behind the kernel's back); a plain
`mount -o remount` does not reliably invalidate dentries for such
changes. The test asserts the observable contract: no unhandled "needs
remounting" warning and a coherent merged view afterwards.

### D6: Replication suite mechanics (`tests/overlay-nix-ota-invalid-vm.nix`)

Mock packages: `pkgs_1` = `pkgs.busybox` (static ELF — safe as a shebang
interpreter with no deps of its own); `pkgs_2` = `runCommand` writing
`$out/bin/tool` with shebang `#!/nix/store/<pkgs_1>/bin/busybox sh` — a
genuine runtime closure reference (the reference scanner picks the path
up, so `pkgs_1` is in `pkgs_2`'s closure); `pkgs_3` = `hello` baked only
into v2's lower (existing marker pattern). Fixture: v1 image carries
`pkgs_1` (and NOT `pkgs_2`); v2 carries neither.

World-A seeding: the host generates 5-line validity records for `pkgs_1`
from `nix path-info --json`; a first-boot oneshot on the v1 appliance
pipes them into `nix-store --load-db` (the no-copy-up property is the
reason for `--load-db` over `--register-validity` — see Context). Then
`nix-store --realize <pkgs_2>` fetches from the deployer's nix-serve
cache and lands ONLY `pkgs_2` in the upper (`pkgs_1` resolves as already
valid). Assertions per the spec matrix:

- v1: tool runs; `! test -d upper/<pkgs_1>` (the seeding held).
- swap, mode `"none"`: tool fails with a missing-interpreter error;
  `nix-store --verify` reports the dangling entries (world-A contract).
- mode `"wipe"`: no stale upper content or DB entries after the swap; the
  new lower is visible through a functional merged store.
- mode `"reconcile"` + cache serving `pkgs_1`: tool runs again; ONLY
  `pkgs_1` was re-fetched into the upper (delta proof).
- mode `"reconcile"` + cache withholding `pkgs_1`: boot completes, the
  reconcile unit is red naming `pkgs_1`, unrelated upper content intact.
- GC probe: realize → GC before the swap → no unhandled remount warning
  (D5 contract); then swap continues per mode.
- tmpfs-upper variants: lifecycle behaviour degenerates to "nothing to
  preserve" — assert overlay health after swap only.

Harness: the `overlay-nix-ab-swap-vm` machinery (driver-created appliance
from a real image, deployer node with nix-serve + nginx staging), extended
with the seeding oneshot, mock packages and mode parameterization. The
suite is the research deliverable: if any branch behaves differently than
this design predicts, the DESIGN is updated to the observed truth before
the module option ships.

### D7: e2e gap suites on the proven harness

| suite | mechanism |
|---|---|
| `ab-ota-rollback-vm` | fixture knob: v2 carries a failing unit listed in `criticalUnits` → Tier-0 keeps `boot-complete.target` unreached → tries exhaust → previous blessed entry boots; assert version marker + exhausted (+0/-N) entry + stability. Observed on the way: instance selection is version-driven — a post-rollback higher-version update targets the RUNNING (oldest) slot and EIO-crashes it, so the suite does NOT install v3 after the rollback; the hazard is documented in ota.md and removing failed instances first is the operator procedure |
| `ab-ota-noop-vm` | run the action twice with the same `NIXTACHE_AB_VERSION`; second run: slot label/`mtime` unchanged, journal shows "no new image", trigger green |
| `ab-ota-drift-vm` | target-side SSH gate patched in-test to the pre-disk-space-gate command set → action's query rejected → target skipped with `::warning::`, job green |
| `ab-ota-interrupted-vm` | SIGKILL `systemd-sysupdate` mid-transfer → reboot → old version boots; stage the next update → slot fully rewritten, update completes |
| `ab-ota-migrate-vm` | normal live-deployed VM (deploy-target, no slots) + empty disk → enable `ab.partitions.autoInit` → first OTA lands and is blessed → assert live generation still bootable → deploy map entry flipped to `ab-image` delivers an image update |

Drift's canonical requirement stays in `direct-deploy` (protocol drift);
the suite exercises it in `checks.ab-deploy-drift` (extracted action text
vs a fake pre-change SSH gate — no VM needed, the drift logic is action
bash).

Observed during implementation (recorded truth):
- `systemd-sysupdate update --reboot` (the remote A/B trigger) reads
  IMAGE_VERSION from os-release; hosts without `system.image.version` make
  it exit 1 silently — ab-provision now warns, and `ab-ota-verify-vm` sets
  the version on its plain-VM target.
- The gnupg PATH drop-in covered only `systemd-sysupdate.service`; both
  modules now equip `systemd-sysupdate-reboot.service` too.
- `ab-ota-anywhere-vm` and verify-vm's C4 leg are RED PRE-EXISTING on
  clean `fa1284a` (nixpkgs bump: `--reboot` settles into a green no-op
  after the booted-version assessment; a manual plain update reports
  `Signature verification failed`). Documented as known-red in
  testing.md; fixing them is follow-up work outside this change.

### D8: KVM CI workflow — schedule + dispatch, no new module option

`.forgejo/workflows/vmtests.yml`: `workflow_dispatch` (full matrix or a
named smoke subset) + weekly schedule for the full matrix; nightly smoke
(one `ab-ota-e2e` variant + the replication suite) keeps the KVM path
warm without multi-GB rebuilds every night. `runs-on: kvm`-labelled
runner; per-suite `timeout-minutes`; each step builds
`.#vmTests.x86_64-linux.<suite>` and prints its report; logs artifact on
failure; `concurrency: 1`. Runner prerequisites (documented in
testing.md + the runner docs pointer): `/dev/kvm` bind-mounted into the
runner container (`containers.<name>.bindMounts."/dev/kvm"`), host
`nix.settings.system-features = [ "kvm" "nixos-test" ]` — the module
already propagates system-features into the container. Decision: NO
`runner.enableKvm` convenience option for now — a documented two-line
snippet beats option sprawl; revisit if the zen3 cluster deployment
proves it clunky.

### D9: Documentation IA (single home per fact)

- `doc/user_guide/ota.md` — concepts (slots, transfers, UKI, boot
  counting, signing), first-deploy matrix (anywhere/disko route —
  reference implementation `tests/ab-anywhere-install.nix`; existing-disk
  `autoInit` route; runner-host gating route), CI wiring + runtime
  versioning, upgrade/rollback story incl. size-mismatch resolution
  (absorbed from migration.md §3), links to `ab-ota` capability.
- `doc/user_guide/overlay-nix.md` — three-worlds model, persistence
  table (tmpfs / persistent / lifecycle modes), hazards + limitations
  (lower-path invisibility & duplication, unbounded growth), GC
  semantics, links to `overlay-nix` capability.
- `deploy.md`: absorbs migration.md §5 essence (module-first-then-action
  upgrade order, `sshGate = "restrict"` hatch); drops migration links.
- `auto-update.md`: drops migration link; points ab-path readers to
  ota.md. `modules/auto-update` option description + assertion messages
  lose their migration.md pointers.
- README: module rows link ota.md/overlay-nix.md; documentation-layers
  table updated; vmTests/CI note.
- `doc/GLOSSARY.md`: slot, appliance, sysupdate-package, staging, UKI,
  boot counting, gating, upper/lower layer, merged store.
- `doc/technical_details/testing.md`: new suites + vmtests.yml + the
  lower-world rule (every overlay test names its world).
- migration.md §3/§4 → `doc/archive/migration-finalize-direct-deploy.md`
  with a freeze note; §1/§2 die as duplicates; §5 essence lives in
  deploy.md.

## Risks / Trade-offs

- [Reconcile needs a reachable substituter; appliances are typically
  offline] → spec'd degraded branch: red unit + named paths, boot
  unaffected; option description states the requirement; marker persists
  for retry on next boot.
- [Wipe stops the nix daemon at the update boundary] → deliberate
  instant, races lose progress coherently (files and DB wiped together);
  documented; no-op-update case restarts the daemon immediately.
- [Remount hook vs. running processes] → full unmount+remount with EBUSY
  retries; worst case a stale dentry until next remount — files remain
  coherent because dedup deletes bypass the merged view; the test pins
  the observable contract, not the mechanism.
- [Overlay-GC semantics are Nix-version-dependent] → the replication
  suite pins behaviour against the SHIPPED nixpkgs revision; a nixpkgs
  bump that changes semantics turns the suite red instead of silently
  changing appliances.
- [Broken-boot e2e flakiness] → `ukiTries` pinned low (2), generous boot
  waits, serial-console assertions on entry selection; the suite is
  excluded from the nightly smoke subset.
- [`--load-db` is legacy CLI] → used only in the test fixture and
  documented; direct SQLite seeding is the recorded fallback if a future
  Nix drops the command.
- [World-A seeded test does not match production world B] → it is the
  forward-compatibility contract (any future lower-DB feature or manual
  registration accident); overlay-nix.md names the worlds explicitly so
  nobody over-reads world-C test results.

## Migration Plan

No consumer-facing breakage: the option defaults to `"none"` (today's
behaviour); all new units are inert without it. Adoption: bump input →
choose `upperOnUpdate` per policy (corpo server: `"reconcile"` once the
zen3 CI runs the matrix green; tmpfs-upper appliances need nothing).
Rollback: unset the option — capture/reconcile markers are inert, the
wipe unit stops being pulled in.

## Open Questions

- Exact vmtests.yml cadence (weekly-full + nightly-smoke chosen in D8) —
  tunable after the zen3 cluster exists; does not affect task shape.
- Whether degraded reconcile retries need a timer instead of
  next-boot-only — deferrable; the enum and units are unaffected either
  way.
- CI lint for stale migration.md references vs. the manual sweep —
  deferrable hygiene follow-up.

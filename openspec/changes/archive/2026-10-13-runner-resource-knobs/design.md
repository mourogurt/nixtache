# Design

## Context

`modules/runner/default.nix` already owns flat resource options
(`memoryMax`, `memoryHigh`, `timeoutStartSec`) applied to
`systemd.services."container@<name>".serviceConfig`. Two facts verified
during exploration shape the approach:

- NixOS container units run `systemd-nspawn --keep-unit` with
  `Slice=machine.slice`, so the payload is charged to the unit's own cgroup
  under `machine.slice/` — unit-level `serviceConfig` limits genuinely govern
  the container (the cgroup paths for inspection are
  `/sys/fs/cgroup/machine.slice/container@<name>.service/`, NOT
  `system.slice/`).
- Repo contract: flat camelCase options mirroring systemd directive names,
  every `mkOption` documented (docs build is `warningsAreErrors`) and covered
  by a pure-eval assertion in `tests/runner.nix`.

Motivation and the incident behind this change: see proposal.md.

## Goals / Non-Goals

**Goals:**

- Three new knobs (`memorySwapMax`, `cpuWeight`, `ioWeight`) identical in
  shape to the existing memory knobs.
- New memory defaults sized for a shared host (16G/14G).
- Unset knobs omit the systemd directive entirely (host/systemd policy
  applies), not "set the systemd default explicitly".
- Docs: one technical-details page (sizing internals + kill diagnostics), one
  user-guide sizing note, each fact in exactly one file per the repo's docs
  invariant.

**Non-Goals:**

- Per-instance or per-job resource isolation. Builds run in the
  container-wide nix-daemon cgroup; per-instance limits cannot isolate build
  memory. The mechanism for that would be separate containers — a different
  change.
- Hard CPU caps (`CPUQuota`) or core pinning (`AllowedCPUs`). Fairness
  weights were chosen in exploration; hard caps waste idle host capacity.
- Configuring or managing systemd-oomd (host or container side). It is a
  debugging-trap documentation topic, not a module surface.
- Auto-tuning `nixSettings.cores` from `memoryMax`. Documented guidance
  instead of hidden coupling.

## Decisions

### D1: Flat options, no structured `resources.*` submodule

Add `memorySwapMax`, `cpuWeight`, `ioWeight` as flat siblings of
`memoryMax`/`memoryHigh`. Alternatives considered: (a) a structured
`resources.{memory,cpu,io}` submodule — nicer grouping, but either breaks
the existing `memoryMax`/`memoryHigh` names or needs
`mkRenamedOptionModule` alias machinery, both heavier than the win; (b) a
generic `containerServiceConfig` passthrough attrset — untyped, undocumented
semantics, untestable per the repo contract (every option documented +
asserted). Flat options keep the surface uniform and each knob individually
documented and tested.

### D2: `nullOr` types with `null` default = omit the directive

`cpuWeight`/`ioWeight` are `nullOr (ints.between 1 10000)`; `memorySwapMax`
is `nullOr str`. When `null`, the module emits no directive, so host-wide
systemd defaults/policy (`DefaultCPUWeight`, admin drop-ins) apply.
Alternative — concrete defaults (100 / infinity): would shadow host policy
with module opinion and clutter the unit file. `null` defers correctly.

### D3: Fairness weights, not quotas

CPU and IO control is weight-based: weights only bite under contention, so a
build uses all idle cores/IO but co-hosted services keep their share when
active. `CPUQuota` would slow CI even on an idle host. (Confirmed with the
consumer during exploration: "достаточно веса".)

### D4: New defaults 16G/14G, static (not derived)

`memoryMax = "16G"`, `memoryHigh = "14G"` preserve the existing 2G gap:
`MemoryHigh` applies reclaim pressure (pushing cold pages to swap) before
`MemoryMax` triggers the kernel cgroup OOM killer — throttle first, kill
last. Alternative — deriving the `memoryHigh` default from `memoryMax`:
rejected; it would silently shift `memoryHigh` when a consumer sets only
`memoryMax`, and NixOS consumers expect static, greppable defaults. Docs
state the recommended gap instead.

### D5: Big-build survival story is host swap, not reduced parallelism

At a 16G RAM budget, chromium-class link peaks are absorbed by host swap
(zram on the reference host) rather than by lowering `nixSettings.cores`:
build speed is preserved, peaks compress into RAM-backed swap.
`memorySwapMax` therefore defaults to unset (fully available) and exists to
protect co-hosted services' swap, not to enable survival. The user-guide note
documents the corollary: hosts with no swap must lower `cores` or raise
`memoryMax` for chromium-class builds.

### D6: Docs placement per the repo's docs-structure invariant

New fact inventory, each living in exactly one file:

- `doc/technical_details/` (new page, internals): cgroup placement under
  `machine.slice`, what `MemoryMax`/`MemoryHigh`/`MemorySwapMax`/weights do
  to the unit, and the "who killed the build" decision tree —
  `memory.events`/`memory.peak` counters, kernel-log search that matches
  ("out of memory", not "oom"), both systemd-oomd layers leaving no dmesg
  trace, and CI-side job cancellation surfacing as signal 9 via Nix's SIGTERM
  handler.
- `doc/user_guide/` (consumer-facing): sizing guidance (budget + swap buffer
  + cores trade-off) and the inline upgrade note for the changed defaults
  (repo rule: no standalone migration docs).
- `doc/user_guide/quickstart.md` line listing resource limits is extended to
  the new knobs; README map line only if it enumerates them.

### D7: Pure-eval tests only

New assertions in `tests/runner.nix` follow the existing pattern: evaluate
`nixosSystem` with the module and assert on
`systemd.services."container@runner".serviceConfig` — defaults (16G/14G,
swap/cpu/io directives absent) and each knob set (values pass through).
Weight bounds are enforced by the option types; no VM test is warranted (no
runtime behavior beyond systemd parsing the unit, which nixpkgs covers).

## Risks / Trade-offs

- [Consumers on dedicated hosts silently drop from a 60G to a 16G budget on
  upgrade] → BREAKING marker in the proposal, inline upgrade note in the user
  guide, and the new values are inspectable pre-deploy via
  `nixos-rebuild dry-activate` / `systemctl show` after switch.
- [At 16G with no host swap, chromium-class builds can OOM deterministically]
  → documented sizing guidance: lower `nixSettings.cores` or raise
  `memoryMax`; the default targets shared hosts, not maximal builds.
- [Host systemd-oomd (enabled by default in recent NixOS) can kill the
  container's leaf cgroups before kernel limits if the host enrolls slices]
  → out of module scope; covered in the diagnostics decision tree so the next
  incident doesn't take a day to explain.
- [`IOWeight` is advisory and depends on host IO controller enablement]
  → documented in the option description.

## Migration Plan

Consumers relying on the implicit 60G/58G defaults pin `memoryMax`/
`memoryHigh` explicitly at upgrade. Rollback: set the options back to the old
values (`"60G"`/`"58G"`); no state or data migration is involved.

## Open Questions

- The final root cause of the incident build kill (Forgejo restart via host
  auto-update vs job-level timeout) is pending the consumer's host-side
  checks. It changes neither the specs nor the design: the diagnostics page
  covers both branches of the decision tree either way.

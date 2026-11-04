# Testing & coverage

How nixtache is tested, what "coverage" means for a declarative NixOS module
flake, and the rules every change must follow. Documentation requirements:
[`openspec/specs/docs/spec.md`](../../openspec/specs/docs/spec.md).

## Testing strategy

`checks.<system>` contains fast eval-oriented suites. Each scenario evaluates
a `nixosSystem` (or calls a lib helper) with specific option values and asserts
on the resulting `config.*` attributes or on a small derivation's build
behavior. These checks run in every `nix flake check`.

`vmTests.x86_64-linux` contains the runtime layer: NixOS VM tests that boot
machines and containers and verify behavior such as daemon startup, OTA slot
swaps and overlay repairs. These suites require KVM and are built explicitly,
not by `nix flake check`.

### Layout — eval-oriented suites (`checks.*`)

| File | Covers | Wired as |
|---|---|---|
| `tests/runner.nix` | the runner module (`services.nixtache.runner.*`) — singleton compatibility, named sibling/nested declarations, logical store parents, frozen lower wiring, clone/native exclusions, invalid graphs and path collisions, store paths, multi-instance, optional SSH creds, sandboxing and deploy wiring | `checks.<system>.runner` |
| `tests/deploy-target.nix` | the target side — apply unit, deploy user, polkit, health check, rollback wiring | `checks.<system>.deploy-target` |
| `tests/ab-image.nix` | build-time A/B image config — fixed vs max-disk sizing, Verify, store-tree imaging | `checks.<system>.ab-image` |
| `tests/ab-contract.nix` | cross-module A/B contracts — provisioning, overlay cutover ordering and marker independence, runner store modes | `checks.<system>.ab-contract` |
| `tests/overlay-nix.nix` | the overlay-nix module — policy and lifecycle wiring, logical/physical derivation, first-child promotion and rebase, operation dispositions and fingerprints, target descriptor validation and planner differential cases | `checks.<system>.overlay-nix` |
| `tests/ab-existing.nix` | compression/UKI options, runner A/B staging assertions and retain-GC wiring, `hostBackup`, `deploy-target.ab.forceAfterTimeout`, native-store/A/B assertion | `checks.<system>.ab-existing` |
| `tests/auto-update.nix` | the auto-update module — methods, assertions, timer/reboot wiring | `checks.<system>.auto-update` |
| `tests/ab-deploy-drift.nix` | the deploy action's protocol-drift skip contract (extracted action.yml text vs a fake old SSH gate) | `checks.<system>.ab-deploy-drift` |
| `tests/ci-workflow-drift.nix` | real workflow/action contracts: sandbox ordering, private-input SSH wiring, consumer/self update profiles, online-`kvm` discovery with `test` fallback, KVM-gated full VM inventory and skip behavior, deferred LFS checkout and ordering, plus fake-endpoint LFS transport scenarios (SSH preference, HTTPS fallback, explicit endpoint preservation and redacted failure) | `checks.<system>.ci-workflow-drift` |
| `tests/mkDocs.nix` | `lib/mkDocs.nix` — the `docStrictMode` flag × documentation-completeness matrix | `checks.<system>.mkDocs` |

`tests/ab-fixture.nix`, `tests/ab-anywhere-install.nix`,
`tests/ab-ota-vm-lib.nix` and `tests/overlay-tree-vm-lib.nix` are shared
fixtures/helpers, not registered suites.

### Layout — KVM-only VM suites (`vmTests.x86_64-linux`)

VM suites carry `requiredSystemFeatures = [ "kvm" ]` and run in CI via
[`.forgejo/workflows/vmtests.yml`](../../.forgejo/workflows/vmtests.yml) on a
KVM-capable runner (label `kvm`): manual full/smoke dispatch plus weekly-full
and nightly-smoke schedules. A manual dispatch may instead set `suite` to one
exact suite name from the inventory below; non-matching matrix jobs skip
without building, and `suite` overrides `subset`. Full inventory:

- Base A/B and transport: `ab-deploy`, `ab-ota-e2e`, `ab-ota-e2e-erofs`,
  `ab-ota-e2e-none`, `ab-ota-anywhere-vm`, `ab-vm`, `ab-provision-vm`,
  `ab-ota-rollback-vm`, `ab-ota-noop-vm`, `ab-ota-interrupted-vm`,
  `ab-ota-migrate-vm`, `ab-ota-migrate-boot-vm`,
  `ab-ota-migrate-boot-override-vm`, `ab-data-pool-vm`,
  `ab-data-pool-wipe-vm`, `ab-runner-compat-vm`, `ab-compression-vm`,
  `ab-staging-vm`, `ab-deploy-self-vm`, `ab-ota-verify-vm`.
- Single-host overlay: `overlay-nix-vm`, `overlay-nix-install-vm`,
  `overlay-nix-ab-swap-vm`, `overlay-nix-ota-invalid-vm` and its `-wipe`,
  `-reconcile`, `-reconcile-degraded` and `-tmpfs` variants.
- Overlay fault injection: `overlay-nix-fault-migration-mv-vm`,
  `overlay-nix-fault-migration-exdev-vm`,
  `overlay-nix-fault-activation-state-vm`,
  `overlay-nix-fault-publication-stage-mv-vm`,
  `overlay-nix-fault-publication-ready-vm`,
  `overlay-nix-fault-publication-current-vm`,
  `overlay-nix-fault-concurrent-vm`,
  `overlay-nix-fault-concurrent-booted-vm`, and
  `overlay-nix-fault-retention-vm`.
- Rooted-tree storage oracles:
  `overlay-tree-{sibling,nested,composed}-{wipe,reconcile}-vm`,
  `overlay-tree-failure-{host,a,grand,b}-vm`, `overlay-tree-parent-root-vm`,
  `overlay-tree-refs-vm`, `overlay-tree-rollback-vm`, and
  `overlay-tree-ephemeral-{host,a}-vm`.
- Topology operations: `overlay-topology-operations-reconcile-vm`,
  `overlay-topology-operations-wipe-vm`,
  `overlay-topology-operations-storage-reset-vm`,
  `overlay-topology-operations-descriptor-missing-vm`, and
  `overlay-topology-operations-descriptor-mismatch-vm`.
- Runner and auto-update: `runner-store-mode-vm`,
  `runner-builder-isolation-vm`, `runner-store-swap-clone-vm`,
  `runner-store-swap-overlay-vm`, `runner-store-swap-overlay-ephemeral-vm`,
  `runner-store-parent-metadata-freshness-vm`, `auto-update-vm`,
  `auto-update-managed-tmpfs-window-vm`, and
  `auto-update-no-intermediate-reboot-vm`.

### Runner production coverage and the operation matrix

"Production" and "storage oracle" are different evidence levels. A test that
uses the real runner options proves declaration-derived container wiring; a
fixture that supplies internal low-level nodes can still check storage repair,
but says nothing by itself about consumer option handling.

| Evidence level | Current suites and operations | Scope and limit |
|---|---|---|
| Production declarations, pure eval | `checks.runner` evaluates singleton and named runner containers, siblings, nesting, clone/native exclusions, unsafe or missing parents, cycles and component-wise path collisions. | Checks declaration-derived configuration without booting containers or applying an operation sequence. |
| Operation algebra, pure eval | `checks.overlay-nix` compares first-child promotion, rebase, add/reparent/remove/storage-change plans, lineage and whole-graph fingerprints, and runs descriptor/planner differential cases. | Uses internal logical-node fixtures rather than named runner declarations. |
| Production runner, KVM | `runner-store-swap-{clone,overlay,overlay-ephemeral}-vm` boots the real singleton runner module through slot changes; `runner-store-parent-metadata-freshness-vm` checks isolation followed by preparation, rebase and child restart. | Current KVM runner fixtures use the singleton declaration. They do not exercise named production sibling add/reparent/remove transitions end to end. |
| Operation transitions, KVM storage fixture | `overlay-topology-operations-{reconcile,wipe}-vm` checks first-child promotion, sibling/depth additions, reparenting, removal and final graph/state dispositions. `storage-reset` checks empty replacement state; `descriptor-{missing,mismatch}` checks fail-closed preparation before publication. | Uses an internal low-level topology fixture and an independent expected-operation/graph oracle. It is not production named-runner coverage and uses fixed traces, not generated arbitrary histories. |
| Rooted-tree repair oracles | `overlay-tree-{sibling,nested,composed}-{wipe,reconcile}-vm` checks parent-first repair, sibling isolation, duplicated metadata and atomic readiness; failure, parent-root, `Refs`, rollback and ephemeral variants focus on specific storage invariants. | Synthetic rooted-layer fixtures isolate OverlayFS/Nix mechanics. Passing them is not evidence of runner declaration or container-mount support. |

The current suites split declaration checks from operation and materialization
checks. No current suite applies add/reparent/remove sequences through named
production runner declarations: eval operation fixtures use internal nodes and
KVM runner fixtures use the singleton. Do not present the combined matrix as
production named-runner operation coverage.

### Formal verification: non-goal and future reference models

The current eval and KVM suites are finite examples and fault-injection traces,
not exhaustive verification of arbitrary graphs, unbounded operation sequences
or all crash interleavings. No completed Alloy/TLA+ model, mechanized refinement
proof or proof of the shell, systemd, Nix, SQLite and OverlayFS implementations
is claimed.

A future verification effort could make the implementation correspondence more
formal:

1. Define a pure reference state machine over logical and physical graphs,
   per-node lineage, upper generations, readiness and slot selection. Its
   actions would model add/promote/reparent/remove/storage-reset, rebase,
   publication, interruption/retry and rollback.
2. Use Alloy for bounded graph-operation and path-safety checks, and
   PlusCal/TLA+ for bounded crash, lock, retry and publication interleavings.
   Explicit bounds on nodes, generations and steps would make the results
   counterexample evidence, not unbounded proof.
3. Generate property-based valid and invalid operation histories, compare the
   reference result with production NixOS evaluation and the planner, shrink
   failing traces, and replay representative traces as KVM scenarios. Existing
   fixed operation suites are examples of replayable traces, not a completed
   property-based implementation.
4. Maintain a refinement mapping from abstract states and actions to evaluated
   physical nodes and lineage fingerprints, systemd dependency edges, migration
   and publication journal markers, readiness metadata, frozen-parent roots and
   store URLs. Such a mapping would document observed correspondence; a
   separate mechanized proof would still be required to call it verified
   refinement.

`runner-builder-isolation-vm` runs host and custom-daemon builds concurrently
and checks both cleanup directions: cancelling the host client leaves the
container builder alive to finish its output, and cancelling the container
client leaves the host builder alive to finish. The UID-isolation contract is
in [`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md).

Every `vmTests` suite belongs in the full matrix unless it is explicitly
parked. A parked suite remains locally buildable, its exclusion site names the
open change tracking the rework, and it is re-added when that change completes.
Every non-parked suite must pass a full dispatch.

The `nixtache-self` update profile also discovers suite names directly from
`vmTests.x86_64-linux`, so its pre-push gate cannot drift from the flake
inventory. With `/dev/kvm` that opens read/write, it builds every discovered
suite with at most three concurrent builds, writes each full transcript to
`artifacts/vm-tests/<suite>/full.log` and fails before push on any suite
failure. Without that device, it writes `artifacts/vm-tests/skipped.log` and
continues without VM builds; the runner-selection mechanics are documented in
[workflow-mechanics.md](workflow-mechanics.md#runner-labels), and the canonical
requirements are in
[`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md).

`ab-ota-anywhere-vm` evaluates the install configuration once on the host and
passes its pre-built `diskoScript` and `toplevel` to nixos-anywhere with
`--store-paths` and `--build-on local`. The network-less VMs perform no real
Nix evaluation or builds. The deployer registers the closure roots in its store
DB, both closure-copy endpoints enable `ca-derivations`, and nixos-anywhere
still exercises kexec, disko, closure transfer, `nixos-install` and reboot; the
`--flake` entrypoint is not covered. A fresh QEMU with OVMF then boots the
installed UKI before the signed OTA leg. See the
[`ab-ota` spec](../../openspec/specs/ab-ota/spec.md); the CA-alias rationale
and transport design are recorded in the
[`hermeticity change`](../../openspec/changes/archive/2026-10-30-redesign-ab-ota-anywhere-hermeticity/design.md).

#### vmtests job output contract

Each matrix job (displayed under its bare suite name) keeps its step output
limited to what the suite itself reported, while the complete
`nix build -L` transcript is attached as an artifact — the requirements live
in [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md):

- the suite step writes the full transcript to `artifacts/<suite>/full.log`
  and prints only a verdict view derived from it: the suite's own report
  section (`=== … ===` banner to EOF) or closing driver lines on success;
  the closing build error plus the last 40 log lines, prefixed with
  `build never reached the test`, when the build fails before any test
  executes;
- `Upload suite logs` (`if: always()`) uploads `artifacts/<suite>/` with
  `if-no-files-found: error` — every job leaves a `full.log`, skipped ones
  included (their log states the skip);
- a full-matrix dispatch runs at most `strategy.max-parallel` suites
  concurrently (3): an unbounded dispatch (~30 concurrent KVM suites on one
  runner host) turns unrelated suites into host-level kills — QEMU/build
  processes dying with SIGKILL or connection resets — which look like
  product failures but are runner overload.

Smoke membership (the nightly subset) is decided INSIDE the run step from
the workflow-level `SMOKE_SUITES` list, not via matrix `include:` — on this
Forgejo runner, `include:` entries that add keys to existing matrix values
spawn extra, never-starting jobs that hold the whole run (and the runner)
open. A wedged vmtests run occupies the `kvm` runner indefinitely; cancel
it before dispatching a new one (the dispatch queues behind it otherwise).

A `kvm`-label runner may still deny `/dev/kvm` to build-sandboxed processes
(EPERM via the device cgroup). The test framework's declared-node VMs fall
back to TCG silently in that case; every suite that starts its own QEMU via
`create_machine(start_command=...)` (or pexpect) MUST pass
`-accel kvm -accel tcg` — KVM first, TCG fallback — or its QEMU dies before
the QMP handshake and the job fails with a bare `ConnectionResetError`.
Under TCG the suites are CPU-emulated: expect several minutes per VM boot
and size the matrix concurrency accordingly.

The migrate pair splits the migration contract:
`ab-ota-migrate-vm` pins the live side (provisioning, idempotency, update
machinery ready, live closure retained) and deliberately never boots the
staged image; `ab-ota-migrate-boot-vm` boots a legacy-labeled disk through
the first OTA cutover — unarmed staging does not cut over, wrong labels roll
back safely, and relabeled partitions or forced `fileSystems` devices cut
over with signed staging throughout.

Overlay tests distinguish their lower-DB worlds (see
[`doc/user_guide/overlay-nix.md`](../user_guide/overlay-nix.md)): appliance
suites use the DB shipped in the image, while `overlay-nix-install-vm` uses a
host-store lower with its own database. Results do not transfer between those
worlds. Faithful store imaging is pinned by `checks.ab-image` (a store tree
containing a symlink path) and `overlay-nix-vm` (the symlink survives imaging
and resolves through `nix path-info`).

The `overlay-nix-ota-invalid` matrix covers empty and tampered update attempts,
same-version persistent-upper reboots, target-only wipe/reconcile with GC roots
and per-user profiles, interrupted preparation and unavailable-substituter
retries with active upper/DB/lower-state checksum comparisons, failed
`nixtache-ab-update` reboot suppression and direct boot recovery of an
unprepared UKI, lower-dump checksum recovery into a fresh ready generation,
and physical-slot reuse from the latest active upper. The tmpfs variant covers ephemeral state reset and
lower reseeding. `overlay-nix-ab-swap-vm` and `overlay-nix-install-vm` retain
the default-wipe swap and non-appliance installation contracts.

The `overlay-nix-fault-*` scenarios exercise transactional migration move
failure, cross-filesystem backup handling and interrupted state activation;
interruption after staging publication, readiness and the `current` switch;
installed/booted lock contention; and bounded ready-generation retention.
Retries must preserve the active chain and either adopt a fully published
matching generation or discard an incomplete one. Faults are injected into
test-owned copies of generated scripts, not by replacing production module
behavior in the ordinary suites.

The `overlay-tree-{sibling,nested,composed}-{wipe,reconcile}-vm` matrix uses the shared
rooted-layer fixture to check parent/intermediate/leaf/sibling roots, exact
repair placement and fetch order, independent sibling repairs, duplicated
ancestor metadata, active-tree isolation, atomic unready generations and final
whole-tree closure validation. Wipe variants assert empty target state and
fresh writes after cutover; reconcile variants also cover unavailable-cache
failure and retry. Canonical behavior:
[`overlay-nix`](../../openspec/specs/overlay-nix/spec.md).

The composed-tree groups extend that fixture to two host children and one nested
grandchild. `overlay-tree-failure-{host,a,grand,b}-vm` inject clone
interruption, repair failure and final metadata verification failure at the
named node, followed by successful retry and physical-slot reuse with fresh
registered writes. Lower-DB seed failure is covered only by
`overlay-tree-failure-host-vm`; other nodes report `seed=N/A` because they have
no lower-DB seed phase. The failure matrix runs `reconcile`: wipe has no source
clone or repair, and is covered separately by the composed wipe suite's empty
state and fresh-write assertions. Failure injection modifies test-owned copies
of the generated preparation scripts, not the production module.
`overlay-tree-rollback-vm` covers automatic and manual rollback with unchanged
per-node generations and databases. `overlay-tree-parent-root-vm` rejects a
child that impersonates parent-provided state through its own upper, and
`overlay-tree-refs-vm` rejects or repairs corrupted reference metadata.
`overlay-tree-ephemeral-{host,a}-vm` contains assertions for resetting the
whole tree below the host, or only `a` plus its descendant, while retaining
persistent siblings. The current materializer does not satisfy the
persistent-copy exclusion for a split ephemeral parent, as documented in
[`overlay-nix.md`](../user_guide/overlay-nix.md#ephemeral-chains-and-mixed-storage-limitation);
the suite's presence in the matrix is not evidence that those assertions pass. The composed
auto-update VM checks deferred-source refresh of window writes at the host,
intermediate, leaf and sibling into the target.

`ab-ota-rollback-vm` covers an upper-hosted critical service across failed boot
health, automatic and manual rollback with the original upper generation/DB,
and same-version physical-slot selection. `ab-data-pool-vm` and
`ab-data-pool-wipe-vm` pin the same upper-preservation rule on ZFS independently
of the policy applied to the new target.

`runner-store-swap-overlay-vm` reconciles the host and runner upper chain,
checks CI-write isolation between slots and restores the original runner
upper and database after failed-boot rollback through the dedicated parent
lower root. `runner-store-swap-overlay-ephemeral-vm` reboots with a tmpfs host
upper and checks that the runner descendant's upper, work directory and Nix
state are reset before CI builds resume. `runner-store-swap-clone-vm` checks
the additive, single relocated-store contract and confirms that clone remains
outside upper metaslots. `runner-store-parent-metadata-freshness-vm` first
checks that parent runtime files and validity records stay absent from the
running child, then prepares a new frozen lower and checks their coherent
appearance after the child restarts; it does not weaken freshness into an
implicit live metadata read. Canonical behavior:
[`runner`](../../openspec/specs/runner/spec.md).

`auto-update-no-intermediate-reboot-vm` checks that v2 then v3 without a
reboot publishes and selects the exact ready v3 generation.
`auto-update-managed-tmpfs-window-vm` contains managed ephemeral-window
assertions, but the current source-fingerprint implementation cannot complete
that scenario. Its presence in the matrix is not a passing result. The
restriction and workaround are documented in
[`auto-update.md`](../user_guide/auto-update.md#ab-upper-readiness-and-deferred-reboots).

### Pure-eval suite and scenario shape

A registered pure-eval suite returns a report derivation whose builder prints
one `ok`/`FAIL` line per check and exits non-zero on failure. Its arguments
depend on the suites it evaluates; shared helpers can instead return attrsets,
and VM suites use the NixOS test runner. Build a report with:

```bash
nix build .#checks.x86_64-linux.runner && cat ./result
```

A new pure-eval test file MUST be registered in `flake.nix`; a new VM suite
goes into `vmTests.x86_64-linux`, never into `checks`:

```nix
checks.${system} = {
  runner = import ./tests/runner.nix { inherit nixpkgs self system; };
};
vmTests.x86_64-linux.my-suite = import ./tests/my-suite.nix {
  inherit nixpkgs self;
  system = "x86_64-linux";
};
```

Runner scenarios evaluate a host and assert on its configuration:

```nix
hostSrv = mkHost "/srv" { services.nixtache.runner.enableSandbox = false; };
svcSrv = servicesOf hostSrv;
scenarioSrv = {
  name = "store.path=\"/srv\" relocates the store; SSH off → no key wiring";
  checks = {
    hasCustomDaemon = has svcSrv "nix-daemon-custom";
    forgejoBindPaths = svcSrv."forgejo-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
    noSshLoadCredential =
      !(hasCredPrefix "flake_ssh_" (loadCred svcSrv)
        || hasCredPrefix "update_ssh_" (loadCred svcSrv));
    noSandboxCap = !(lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities);
    hasIpcLock = lib.elem "CAP_IPC_LOCK" hostSrv.config.containers."runner".additionalCapabilities;
  };
};
```

A scenario is `{ name, checks }`; the suite aggregates `scenarios = [ ... ]`
and fails iff any check is false.

### Build-failure assertions (mkDocs tests)

Pure eval catches eval-time throws (for example, failed assertions through
`builtins.tryEval`) but not build-time failures. The `mkDocs` suite handles
the strict-mode matrix as follows:

- cases that must build are interpolated into the test builder, making them
  real dependencies whose failures fail the test;
- the strict + undocumented case is not referenced by the builder at all —
  even a `.drvPath` reference would make `nix flake check` reach the failing
  options build. The suite verifies its eval-time precondition (an
  undocumented option exists), while nixtache's own strict
  `packages.optionsMarkdown` build exercises the rejection mechanism.

## Rules (also in AGENTS.md)

1. **Every `mkOption` MUST have a `description`.** Enforced in CI:
   `nixosOptionsDoc` for this flake's own `packages.optionsMarkdown`/`JSON`/`HTML`
   runs with `warningsAreErrors = true`, so an undocumented option breaks the
   docs build. (`mkEnableOption` auto-generates one, so it's exempt.) Consumers
   opt into the same strictness via `nixtache.lib.mkDocs { docStrictMode = true; }`.
2. **Every option MUST be covered by a test.** When adding an option or
   changing behavior, add or extend a scenario in `tests/` and run
   `nix build .#checks.<system>.<suite>`.

## What "coverage" means for Nix

Classic line-coverage does not describe a declarative module's behavior. The
useful measures are:

- **Option coverage:** every consumer-facing option under
  `services.nixtache.*` (and every `lib.mkDocs` parameter) is set to a
  non-default value and/or has its resulting configuration asserted.
- **Branch coverage:** every meaningful configuration branch is exercised.
  Runner examples include native vs relocated stores, sandbox on/off,
  optional credential bundles, single vs multiple instances and cache on/off;
  the sibling modules have their own method, policy and failure branches.

## Running tests

```bash
# Evaluate flake outputs and build all checks:
nix flake check --show-trace --all-systems

# One pure-eval suite, with the printed report:
nix build .#checks.x86_64-linux.runner && cat ./result
nix build .#checks.x86_64-linux.mkDocs && cat ./result

# KVM VM suites (CI runs them via vmtests.yml):
nix build .#vmTests.x86_64-linux.ab-deploy
nix build .#vmTests.x86_64-linux.overlay-nix-vm
```

### Provisioning a KVM runner for `vmtests.yml`

The workflow's `kvm`-labelled runner needs host-side system features and
access to `/dev/kvm` inside the runner container:

```nix
nix.settings.system-features = [ "kvm" "nixos-test" "big-parallel" ];
containers.<runner-name>.allowedDevices = [
  { node = "/dev/kvm"; modifier = "rwm"; }
];
containers.<runner-name>.bindMounts."/dev/kvm" = {
  hostPath = "/dev/kvm";
  isReadOnly = false;
};
```

A bind mount alone can leave `open(/dev/kvm)` failing with `Operation not
permitted` even when the node is visible as `crw-rw-rw-`: `allowedDevices`
grants the container's device-cgroup access, while `isReadOnly = false` avoids
mount-level write restrictions. The self-update capability probe checks the
actual open, not just the node or its mode bits.

`runNixOSTest` adds the `kvm` and `nixos-test` requirements; pexpect-based
suites declare `kvm` themselves. Give the runner instance the `kvm` label so
`runs-on: kvm` resolves:

```nix
services.nixtache.runner.instances.kvm = {
  uuid = "…";
  tokenFile = config.sops.secrets.runner-token-kvm.path;
  labels = [ "kvm:host" ];
};
```

If the runner is itself a VM, enable nested virtualization or prefer
containers on bare metal.

Self-CI (`ci.yml`) runs on pushes to `main`, all pull requests and manual
dispatch. It runs `nix flake check`, prints each
`checks.x86_64-linux.<suite>` report, and generates the `nixtache-options`
artifact.

## Adding a new option or test — checklist

1. Declare the option with a `description`.
2. Add a scenario that sets the option and asserts its resulting `config.*`;
   add the opposite value too if it has a meaningful off-branch.
3. Run `nix build .#checks.<system>.<suite>` and read the report.
4. If the option belongs to a new area, create `tests/<area>.nix` and register
   it in `flake.nix` under `checks.<system>` (or `vmTests.x86_64-linux` for a
   KVM suite).

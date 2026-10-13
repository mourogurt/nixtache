# Tasks

## 1. Replication research suite — baseline (world B/A hazard, mode `none`)

- [x] 1.1 Build the mock-package + seeding machinery in the test fixture:
  `pkgs_1` (static busybox), `pkgs_2` (shebang consumer, genuine closure
  ref), `pkgs_3` (v2 marker), the host-side 5-line validity-record
  generator, and the first-boot `nix-store --load-db` oneshot. Verify by
  booting the v1 appliance in the suite: `pkgs_2` realized from the
  deployer cache runs, and `! test -d upper/<pkgs_1>` proves the seeding
  held (no copy-up, upper stays delta-only)
- [x] 1.2 Assert the hazard branches under mode `none`: after the OTA swap
  `pkgs_2` fails with a missing-interpreter error and `nix-store --verify`
  reports the dangling entries; plain-reboot control keeps `pkgs_2`
  runnable; tmpfs-upper variant asserts overlay health after swap only.
  Suite: `tests/overlay-nix-ota-invalid-vm.nix` (D6 harness:
  `overlay-nix-ab-swap-vm` machinery extended)
- [x] 1.3 GC-before-swap probe: realize → `nix-collect-garbage` → record
  the observed GC/remount behaviour (journal evidence) → swap. Any
  divergence from design D4/D5 predictions updates design.md BEFORE the
  module work starts (the suite is the research deliverable)
- [x] 1.4 Wire the suite into `flake.nix` `vmTests.x86_64-linux` and add
  its row to `doc/technical_details/testing.md` (naming its lower-DB
  world). Verify: `nix build .#vmTests.x86_64-linux.overlay-nix-ota-invalid-vm`
  on a KVM host prints the full ok/FAIL report

## 2. overlay-nix module: remount-hook + `upperOnUpdate`

- [x] 2.1 Add the remount-hook script (full unmount+remount of the
  overlay, EBUSY retry) and wire it into `nix.settings`; add pure-eval
  scenarios to `tests/ab-contract.nix` asserting the setting is present
  and the script is executable when overlay-nix is enabled. Verify:
  `nix build .#checks.x86_64-linux.ab-contract`
- [x] 2.2 Declare `services.nixtache.overlay-nix.upperOnUpdate`
  (`"none" | "wipe" | "reconcile"`, default `"none"`, description covering
  the substituter requirement for reconcile and the daemon-stop-at-wipe
  caveat); extend the option-coverage scenarios. Verify: strict docs build
  `nix build .#optionsMarkdown` stays green with the new option documented
- [x] 2.3 Implement `nixtache-overlay-preupdate.service` (wipe branch:
  daemon stop → clear upper+work+`/nix/var/nix` overlay state → daemon
  start; reconcile branch: capture `nix profile list --json` + gc-roots to
  `/var/lib/nixtache/overlay-capture/` + drop marker) attached via a
  `Wants=`/`After=` drop-in on `systemd-sysupdate.service`; pure-eval
  scenarios for unit presence, ordering, drop-in, and `none`-mode
  inertness. Verify: `checks.x86_64-linux.ab-contract`
- [x] 2.4 Implement `nixtache-overlay-reconcile.service` (verify →
  verify --repair → installable replay; marker consumed only on success;
  `ConditionPathExists` marker, ordered after the overlay mount and
  nix-daemon); pure-eval scenarios for ordering, condition and failure
  semantics. Verify: `checks.x86_64-linux.ab-contract`
- [x] 2.5 Extend `overlay-nix-ota-invalid-vm` with the lifecycle matrix:
  `wipe` (no stale upper/DB after swap, new lower visible); `reconcile` +
  cache serving `pkgs_1` (tool runs again, ONLY `pkgs_1` re-fetched —
  delta proof); `reconcile` + cache withholding (boot fine, unit red
  naming `pkgs_1`, unrelated content intact). Verify: KVM run of the suite
  prints all matrix rows ok
- [x] 2.6 Write `doc/user_guide/overlay-nix.md` (three-worlds model,
  upperDir persistence table, lifecycle modes, GC semantics, hazards:
  lower-path invisibility/duplication + unbounded growth) linking the
  `overlay-nix` capability; link the README module row; add glossary terms
  upper/lower layer + merged store; verify every documented command/example
  in the page runs as written (VM suite covers the behavioural claims)

## 3. OTA e2e gap suites

- [x] 3.1 `ab-ota-rollback-vm`: fixture knob for a v2 with a failing
  criticalUnit (Tier-0 blocks boot-complete), `ukiTries` pinned at 2;
  assert tries exhaust → previous blessed entry boots (version marker),
  failed entry has no tries left, rollback slot intact and a fixed v3
  update still installs. Wire into `vmTests` + testing.md row
- [x] 3.2 `ab-ota-noop-vm`: same `NIXTACHE_AB_VERSION` twice; second run
  leaves slot label/mtime unchanged, journal shows no new image, trigger
  green. Wire into `vmTests` + testing.md row
- [x] 3.3 `ab-ota-drift-vm`: target SSH gate patched in-test to the
  pre-disk-space-gate command set; action query rejected → target skipped
  with `::warning::`, job stays green. Wire into `vmTests` + testing.md row
- [x] 3.4 `ab-ota-interrupted-vm`: SIGKILL sysupdate mid-transfer →
  reboot boots the old version; next staged update fully rewrites the
  inactive slot and completes. Wire into `vmTests` + testing.md row
- [x] 3.5 `ab-ota-migrate-vm`: live-deployed VM (deploy-target, no slots)
  + empty disk → `ab.partitions.autoInit` → first OTA installed and
  blessed while the live generation stays bootable → deploy-map flip to
  `ab-image` delivers an image update. Wire into `vmTests` + testing.md row

## 4. KVM CI workflow

- [x] 4.1 Create `.forgejo/workflows/vmtests.yml`: `workflow_dispatch`
  (full matrix or smoke subset) + weekly full schedule + nightly smoke
  (one `ab-ota-e2e` variant + the replication suite), `runs-on: kvm`,
  per-suite `timeout-minutes`, `concurrency: 1`, per-suite report output,
  logs artifact on failure. Verify: YAML lints/dispatches dry-run (real
  execution once the zen3 runner exists)
- [x] 4.2 Document runner prerequisites (`/dev/kvm` bindMounts snippet,
  host `system-features = kvm nixos-test`) in
  `doc/technical_details/testing.md` with a pointer from the runner
  section of `doc/user_guide/quickstart.md`. Verify: a contributor can
  provision a KVM runner from the docs alone

## 5. OTA docs + migration.md retirement

- [x] 5.1 Write `doc/user_guide/ota.md`: concepts (A/B slots, sysupdate
  transfers, UKI + boot counting, signing), first-deploy matrix
  (nixos-anywhere/disko route referencing `tests/ab-anywhere-install.nix`,
  existing-disk `autoInit` route incl. size-mismatch resolution absorbed
  from migration.md §3, runner-host gating route), CI wiring + runtime
  versioning, upgrade/rollback story; link the `ab-ota` capability. Verify:
  every config snippet in the page evaluates (pure-eval spot check) and
  each factual claim maps to a spec scenario or suite
- [x] 5.2 Absorb migration.md §5 essence into `deploy.md`
  (module-first-then-action upgrade order, `sshGate = "restrict"` hatch),
  drop its migration links; fix `auto-update.md` (point ab-path readers to
  ota.md) and strip the migration.md pointers from the
  `modules/auto-update` option description + assertion messages. Verify:
  `grep -rn "migration.md" README.md doc/ modules/` returns only the
  archive-path references added in 5.3
- [x] 5.3 Archive migration.md §3/§4 as
  `doc/archive/migration-finalize-direct-deploy.md` (freeze note pointing
  to `openspec/specs/`), delete `doc/user_guide/migration.md` (§1/§2 die
  as verbatim duplicates). Verify: archive freeze note present; no live
  link to the deleted file anywhere
- [x] 5.4 Update README (module rows link ota.md/overlay-nix.md,
  documentation-layers table, vmTests/vmtests.yml note), AGENTS.md (tests
  inventory, suite count, new workflow in the layout map) and add the
  glossary OTA vocabulary (slot, appliance, sysupdate-package, staging,
  UKI, boot counting, gating). Verify: README map has no linkless module
  rows; AGENTS.md layout matches `flake.nix` outputs

## 6. Integration verification

- [x] 6.1 `nix flake check --show-trace --all-systems` green (all
  pure-eval suites incl. the new ab-contract scenarios + strict docs
  build)
- [x] 6.2 KVM-host run of every new/extended VM suite
  (`overlay-nix-ota-invalid-vm` full matrix, the five ab-ota gap suites)
  with ok reports; first `vmtests.yml` dispatch against the zen3 runner
  once provisioned
- [x] 6.3 `openspec validate ota-stabilization --strict` green and the
  documentation cross-links in place (user-guide pages point at the
  `ab-ota` / `overlay-nix` capability paths that go canonical at archive)

# Proposal

## Why

The full-matrix `vmtests` dispatch (run #80, SHA `1625203`) failed 22 of 32
suites. Log analysis splits the failures into two groups: 12 jobs killed at
the host level (QEMU/build processes SIGKILLed or dying with
`ConnectionResetError` while ~30 KVM-heavy suites ran concurrently on one
runner — infra, not code), and a cluster of genuine, reproducible defects —
plus a workflow that makes every failure needlessly hard to diagnose: the
`Upload suite logs` step has never uploaded anything (nothing ever writes to
`artifacts/`), and the job log is a multi-megabyte wall of build output in
which the actual test verdict is buried.

## What Changes

- Fix the deterministic test-side assertion bugs:
  - `ab-deploy-self-vm` and `auto-update-vm` assert `journalctl -u
    systemd-sysupdate | grep 'Successfully installed'` **after** the flow
    rebooted the target; the volatile journal of the previous boot is gone,
    so the grep fails although the console proves the install succeeded.
    Assert against the boot that performed the install.
  - `ab-vm` T1 fails with `RESULT_BLESS=unknown` on a fresh image even
    though `boot-complete.target` is active: `systemd-bless-boot status`
    returns nothing queryable under the appliance's QEMU boot path. Align
    the assertion (or the module's ABA wiring) with what the image actually
    attains on first boot.
- Root-cause and fix the OTA-flow failures where the update never installed
  yet the trigger's reboot leg rebooted the target anyway, so every
  post-install wait (`abtest_2+*.efi`, slot relabel) times out — hit by
  `ab-ota-e2e-erofs`, `ab-ota-e2e-none`, `ab-ota-e2e-percent`,
  `ab-ota-verify-vm`: the reboot must follow only a completed installation,
  and a failed/no-op update must surface the sysupdate error instead of a
  reboot-plus-timeout.
- Root-cause the two opaque failures:
  - `ab-ota-anywhere-vm`: run #99 pinned it — both nix sides of the CA
    closure copy (deployer client + kexec-installer serve) need
    `ca-derivations`; fixed, and the feature set moves to one
    module-level definition shared by runner container, test deployer
    and kexec installer instead of hand-copied test lists.
  - `ab-compression-vm` K4 (EROFS appliance boot produces **zero** serial
    output before the 240 s pexpect timeout — squashfs boots fine):
    still under investigation.
- Rework `vmtests.yml` diagnosability:
  - the suite step's job output shows only the suite's own output (test
    verdict lines) or a clear "build never reached the test" + error tail;
  - the full `nix build -L` transcript goes to a file under `artifacts/`,
    so `Upload suite logs` actually uploads it on every outcome;
  - matrix jobs are named after their suite (no `suites (…)` prefix);
  - the full-matrix dispatch bounds parallelism (`max-parallel`) so one
    dispatch cannot OOM-kill a single KVM runner the way run #80 did.
- Test-surface hygiene: the created-machine/pexpect QEMU invocation
  (KVM-first with TCG fallback, OVMF, test-LAN wiring) is centralized in
  the shared VM-test lib instead of per-suite copies; the test-only
  workarounds (regInfo load-db, PATH aux-bins) are recorded as
  test-only with their no-prod-surface rationale; the temporary
  vde-repro diagnostic is retired after CI confirms the fallback green.
- The 12 host-killed jobs need no code change; they are expected to pass on
  a healthy runner with bounded parallelism.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- **ci-workflows**: adds requirements for vmtests job output hygiene
  (verdict-only job log, full log as an uploaded artifact, suite-named
  matrix jobs) and for bounding full-matrix concurrency on the KVM label.
- **ab-ota**: adds requirements that the trigger's reboot leg follows only
  a completed installation, and that every slot filesystem variant the
  ab-image module can produce (squashfs, erofs) boots to an operational
  appliance.

## Impact

- Files: `.forgejo/workflows/vmtests.yml`, `tests/ab-deploy-self-vm.nix`,
  `tests/auto-update-vm.nix`, `tests/ab-vm.nix`, `tests/ab-ota-e2e.nix`,
  `tests/ab-ota-verify-vm.nix`, `tests/ab-ota-anywhere-vm.nix`
  (ca-derivations placement), `tests/ab-ota-vm-lib.nix` (shared helpers,
  consolidated QEMU base), `tests/ab-data-pool-vm.nix`,
  `tests/overlay-nix-ab-swap-vm.nix`, `tests/overlay-nix-ota-invalid-vm.nix`,
  `tests/overlay-nix-vm.nix` (QEMU-args consolidation),
  `modules/runner/` (extracted nix-features definition), the deploy-side
  AB action script (reboot-after-install guard),
  `tests/ab-compression-vm.nix` (EROFS investigation), and — if the
  bless-boot root cause lands in the module — `modules/deploy-target/`
  or `modules/ab-image/`. The temporary `tests/vde-repro.nix` diagnostic
  and its `probe-vde.yml` dispatch are retired by this change once CI
  confirms the KVM/TCG fallback.
- Coordination: `deploy-runner-contract-fixes` already tracks artifact-loss
  and suppressed suite reports for the *reusable* CI workflows; this change
  owns the same concerns for `vmtests.yml` specifically and must not
  duplicate its tasks.
- Docs: `doc/technical_details/testing.md` (vmtests log layout, naming,
  parallelism) per the documentation task rule.

# Design

## Context

Run #80 (SHA `1625203`, full-matrix dispatch) classified from job logs:

| Cluster | Suites | Evidence | Verdict |
| --- | --- | --- | --- |
| Host kills | `ab-data-pool-vm`, `ab-ota-interrupted-vm`, `ab-ota-migrate-boot-vm`, `ab-ota-migrate-boot-override-vm`, `ab-ota-noop-vm`, `ab-ota-rollback-vm`, `overlay-nix-ab-swap-vm`, `overlay-nix-ota-invalid-{reconcile,reconcile-degraded,tmpfs,wipe}-vm` | `ConnectionResetError` on QMP the moment the second VM starts; QEMU processes died | infra: ~30 KVM suites at once on one runner; no code fix, prevent with bounded parallelism |
| Host kill | `runner-store-swap-clone-vm` | `builder failed due to signal 9 (Killed)` mid-build | infra, same prevention |
| Journal-after-reboot | `ab-deploy-self-vm`, `auto-update-vm` | console shows `* Successfully installed update '2'`, then `journalctl -u systemd-sysupdate \| grep 'Successfully installed'` exits 1 | test bug: the flow rebooted the target; the volatile journal of the installing boot is gone |
| Reboot without install | `ab-ota-e2e-{erofs,none,percent}`, `ab-ota-verify-vm` | target shuts down (user sessions teardown) while `abtest_2+*.efi` never appears; waits time out at 180/300 s | sysupdate installed nothing; the reboot leg fired anyway |
| First-boot attest | `ab-vm` | `RESULT_BOOT_COMPLETE=active` but `RESULT_BLESS=unknown`; `systemd-bless-boot status` exits non-zero | expectation/contract mismatch on fresh image under QEMU — investigate |
| EROFS boot | `ab-compression-vm` | K4 squashfs boots in ~66 s; K4 erofs emits zero serial bytes for 240 s | unbootable erofs image or boot-chain break — investigate |
| Opaque | `ab-ota-anywhere-vm` | `AssertionError: nixos-anywhere failed with 1`, nothing captured before it | needs logs to diagnose |

Non-goals: the Forgejo UI showing epoch start times / absurd durations for
workflow_dispatch runs (server-side quirk); the reusable-workflow artifact
concerns owned by `deploy-runner-contract-fixes`.

## Decisions

### D1 — vmtests.yml output contract (spec: ci-workflows)

The suite step becomes three phases: (1) `mkdir -p "artifacts/${SUITE}"`;
(2) `nix build -L --no-link --print-out-paths … > "artifacts/${SUITE}/full.log" 2>&1`
full transcript to file, never to the step stream; (3) print a verdict view
from the file: the test-driver section (from the suite's `=== … ===` banner
to EOF) when the test ran, else `build never reached the test` plus the last
~40 lines (mirroring nix's own `Last N log lines`). Extraction is a small
`awk`/`sed` against the banner the suites already print — stable because
the banners are part of each suite's output contract. On any outcome the
existing `Upload suite logs` step (`if: always()`) now finds
`artifacts/<suite>/full.log`; add `if-no-files-found: error` so a silent
no-op can never regress unnoticed. Job display name: `name: ${{ matrix.suite }}`
on the matrix job (drops the `suites (…)` prefix). Parallelism:
`strategy.max-parallel: 3` — seven concurrent suites ran green in run #80;
thirty killed the host; three keeps a full dispatch inside a few hours.

### D2 — Journal assertion (ab-deploy-self-vm, auto-update-vm)

Assert installation evidence in the boot that performed it: either query
before the reboot leg runs, or grep the captured console/serial transcript
(the evidence already printed on the console). Prefer the pre-reboot query
via the shared OTA test helper (`tests/ab-ota-vm-lib.nix`) so both suites
and future ones reuse one `assertSysupdateInstalled` helper. No product
change.

### D3 — Reboot only after install (spec: ab-ota)

In the deploy-side AB trigger script (the action's second leg), gate
`systemd-sysupdate reboot` on the just-run `systemd-sysupdate update`
reporting a successful installation (exit status plus journal evidence from
that boot, per D2's helper semantics). On install failure: do not reboot,
propagate the sysupdate error to the deployer so the suite fails with the
real cause. Update `ab-ota-e2e.nix`/`ab-ota-verify-vm.nix` to assert the
new contract, and add the negative scenario (unreachable staging → no
reboot, error surfaced) as a test case.

### D4 — bless-boot on first boot (ab-vm)

Investigate by reproducing locally (`nix build .#vmTests.x86_64-linux.ab-vm`
on a KVM host): query `systemd-bless-boot status`, `bootctl`, and the ESP's
loader entries on the fresh image. Two outcomes: (a) the image does not
configure boot counting / systemd-boot variables under QEMU → the module
(`modules/ab-image/` or `modules/deploy-target/`) wires it, and the
assertion stays strict; (b) ABA on this platform legitimately attests via
`boot-complete.target` without a queryable bless state → the test asserts
the attainable contract (boot-complete + slot integrity) and documents why
bless status is `unknown` on first boot. Choose (a) only with a concrete
module defect in hand; otherwise (b). If (a) wins, extend the ab-ota delta
in this change with the wiring requirement before implementing.

### D5 — EROFS boot (ab-compression-vm)

Zero serial bytes means the kernel never started — not an initrd mount
failure (that would still print early boot). Reproduce locally; inspect the
erofs repart image (ESP contents, kernel presence, partition offsets)
against the squashfs one. Fix wherever the difference originates (image
definition in `modules/ab-image/`, or the test's image assembly), keep K1–K3
and both K4 boots; the squashfs K4 regression-guards the shared path.

### D6 — ab-ota-anywhere

Re-run after D1 lands so the full transcript is an artifact; root-cause
from it (suspects: ssh/disk-full/kexec under the appliance fixture). No
design commitment until the log exists — the task is investigation-first
with the fix to follow in this change.

## Risks / Trade-offs

- Verdict extraction depends on suite banners; mitigated by the banners
  being the suites' stable output contract and by the full log always being
  the artifact of record.
- `max-parallel: 3` lengthens a full dispatch (~serial sum of suites; the
  per-job 240 min timeout is unaffected). Acceptable for a manual/weekly
  matrix; the nightly smoke subset is unaffected.
- D3 changes trigger behavior; consumers that relied on "reboot regardless"
  would see the target stay up on failed updates — that is the intended,
  now-specified contract.

## Migration Plan

None required: workflow and test-surface changes only; the trigger change
(D3) alters behavior solely on the failure path (no-op/success paths
unchanged).

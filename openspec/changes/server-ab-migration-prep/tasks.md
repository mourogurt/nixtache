# Tasks

## 1. Migrated-disk first-boot suite (D1, D2)

- [x] 1.1 Create `tests/ab-ota-migrate-boot-vm.nix` skeleton: driver-created machine booting a crafted legacy-label disk image (GPT partlabels NOT `root`/`boot`), deployer node staging v2, sysupdate pull without `switch-to-configuration` — verify `nix build .#vmTests.x86_64-linux.ab-ota-migrate-boot-vm` evaluates and the VM boots
- [x] 1.2 Leg A1 (unarmed staging): with the live-era `default nixos-*` pin in loader.conf, a staged UKI is NOT selected at reboot (legacy boots) — verify suite leg green
- [x] 1.3 Leg A2 (armed, labels wrong): remove the `default nixos-*` pin (arming = deletion, NOT a UKI-only glob — the default glob ignores boot assessment) without relabeling → first OTA boot never blesses, boot counting exhausts, machine returns to the pre-migration entry with update machinery alive — verify suite leg green
- [x] 1.4 Leg B (contract honoured): relabel partitions to `root`/`boot` (sgdisk), re-arm the exhausted UKI (`+0` → `+tries` rename) → assert cutover boots the staged image, boot is blessed, legacy Type#1 entries remain on the ESP as fallback — verify suite leg green
- [x] 1.5 Leg C (override hatch): `fileSystems."/"`/`"/boot"` mkForce override to the existing devices (no relabel) → assert same cutover — verify suite leg green
- [x] 1.6 Wire the suite into `flake.nix` `vmTests.x86_64-linux` and the `.forgejo/workflows/vmtests.yml` full matrix (not the smoke subset) — verify the attr builds and the matrix lists it
- [x] 1.7 Document the migrated-disk contract in `doc/user_guide/ota.md` route 2: the `root`/`boot` partlabel requirement (relabel via `sgdisk --change-name`, or the `fileSystems` override hatch), the loader.conf arming step (live-era `default nixos-*` pin keeps a staged UKI from ever booting), mandatory `system.autoUpgrade.enable = false`, the two-phase config flip (provision without `ab-image`, then build images with it) — with a link to `openspec/specs/ab-ota/spec.md` — verify `openspec validate server-ab-migration-prep --strict` stays green and the doc renders the new section
- [x] 1.8 Add the suite row to `doc/technical_details/testing.md` — verify the inventory table lists it with its legs

## 2. Data-pool persistence suite (D4)

- [x] 2.1 Create `tests/ab-data-pool-vm.nix`: appliance + second virtio disk carrying a ZFS pool; import on v1, write state, mock service reads it; swap to v2 → assert pool imports and state reads post-swap — verify suite green
- [x] 2.2 Rollback leg: roll back to v1 (no `zpool upgrade`) → assert the pool still imports and serves state under the older slot's ZFS — verify suite leg green
- [x] 2.3 Overlay-upper-on-ZFS leg: overlay-nix `upperDir`/`workDir` on a pool dataset → assert the merged store mounts after `zfs-mount.service` and works pre/post swap — verify suite leg green; if ZFS uppers prove unsupported, document the ext4-root fallback instead of changing defaults
- [x] 2.4 Wire into `flake.nix` + `vmtests.yml` full matrix; document upper-on-ZFS (works on OpenZFS ≥ 2.2, mount ordering, ext4 fallback) in `doc/user_guide/overlay-nix.md` with a link to `openspec/specs/ab-ota/spec.md`; add the testing.md row — verify doc sections render and the matrix lists the suite

## 3. Runner store across a swap (D3)

The `lower-store-db` work provides the prerequisite validity records and
runner-container wiring. The suite exists (`tests/runner-store-swap-vm.nix`,
wired into `flake.nix` `vmTests`); what remains here is verification of both
modes and documentation, not another store redesign.

- [x] 3.1 Finish `tests/runner-store-swap-vm.nix`: `mkAppliance` embedding the runner container closure and a trivial build through the relocated store on v1 — verify the pre-swap build succeeds in CI
- [x] 3.2 Clone variant: swap, reboot → assert the re-clone is additive and a post-swap build succeeds (the nspawn bind-path guarantee already landed; the container appliance-mode wiring is `lower-store-db`'s group 3) — verify suite leg green and `nix flake check` passes
- [ ] 3.3 Overlay variant: swap, reboot → assert the merged view is coherent and a post-swap build succeeds — verify suite leg green
- [ ] 3.4 After `lower-store-db` wires the matrix: verify both suite modes report PASS in the full-matrix job log; note the runner-store-across-swaps behaviour under `doc/user_guide/ota.md` route 3 (gated self-update) with a link to `openspec/specs/runner/spec.md`; add the testing.md row — verify docs render

## 4. Overlay reconcile replay leg (D5)

- [x] 4.1 Extend `tests/overlay-nix-ota-invalid-vm.nix`: pre-swap `nix profile install` of the mock tool (hermetic, RAM-cheap, per the suite's realize rationale) → assert the capture records the per-user profile target in `roots.txt` — verify the pre-swap assertions pass
- [x] 4.2 Reconcile variant: assert the recorded profile installable is replayed post-swap (tool runs via the profile); `none`/`wipe` variants assert the negative (broken / gone) — verify all three variants green

## 5. Integration

- [x] 5.1 `nix flake check --show-trace --all-systems` green and `openspec validate server-ab-migration-prep --strict` green — verify both commands
- [ ] 5.2 Full `vmTests` matrix green on a KVM runner (manual dispatch of `vmtests.yml` with the full subset) — verify every suite, including the three new ones, reports PASS in the job log

## 6. Deterministic absolute slot sizing (D7)

- [x] 6.1 Make `ab-image.storeSize` and `deploy-target.ab.partitions.slotSize` reject percentages at evaluation with an actionable absolute-size message; delete the image-build `2G` percentage fallback, assertion bypass and provision-time percentage resolver while preserving absolute parsing and co-import equality checks — add pure-eval cases for both rejected options, accepted absolute values and mismatched co-imported sizes
- [x] 6.2 Remove `ab-ota-e2e-percent`, the S4 percentage leg in `ab-provision-vm`, percent-only branches in `ab-ota-e2e.nix`, and their `flake.nix` / `vmtests.yml` entries — verify no maintained test or matrix entry relies on percentage sizing
- [x] 6.3 Update `doc/user_guide/ota.md`, option descriptions and `doc/technical_details/testing.md` for absolute-only sizing, including an actionable upgrade note for existing percentage configurations — verify links and OpenSpec deltas without local CA builds

## 7. Auto-update, provisioning and rollback correctness (D8, D9)

- [x] 7.1 Change the A/B auto-update poll to `systemctl start --wait` on `systemd-sysupdate-update.service` (systemd ≥ 262) or `systemd-sysupdate.service` (older releases) before journal inspection; add positive staged-image coverage for `if-needed` and `window`, plus a no-new-image control — verify in the existing CI auto-update suite, not a local CA rebuild
- [x] 7.2 Correct non-cross-midnight reboot-window comparison to `now >= start && now < end`, retain the wrapping predicate for cross-midnight windows, and add cheap scripted cases for before/start/inside/end/after and persistent catch-up with a controlled clock and reboot stub
- [x] 7.3 Add `slotSize` reduction to the low-space provisioning remedies and assert the message in the provision contract — verify through the CI provision coverage
- [x] 7.4 Implement the D9 post-rollback recovery path after checking for a sysupdate-supported complete-instance removal operation; preserve the running slot, refuse ambiguous deletion and never rely on bare vacuum for a boot-failed complete version
- [x] 7.5 Extend `ab-ota-rollback-vm` to execute that recovery and install a fixed higher version, asserting the running slot is never overwritten and the fixed image boots; document the tested procedure in `doc/user_guide/ota.md` — run the suite in KVM CI

## 8. Test and documentation reconciliation (D4, D10)

- [x] 8.1 Split `ab-data-pool-vm` assertions by concern: pool/state persistence independent of upper policy; explicit `reconcile` + retained substituter for the upper-intact leg; a default-wipe control expecting cleared upper content — verify in KVM CI
- [x] 8.2 Update `ab-contract` to current `upperOnUpdate = "wipe" | "reconcile"` and lower-DB semantics, remove missing-module/expected-red fallbacks, register it in `checks` and the self-CI report loop — verify its report in CI
- [x] 8.3 Remove stale expected-red/known-red narratives from auto-update and overlay test entry points and make them import implemented modules directly — verify static Nix parsing and the relevant CI suites
- [x] 8.4 Reconcile all maintained docs with the new sizing, rollback, auto-update and data-pool behavior and with `wipe-on-cutover`; run `openspec validate server-ab-migration-prep --strict` and `openspec validate --specs --strict` without local AB/CA builds
- [ ] 8.5 Use the existing full KVM CI matrix in task 5.2 for CA-dependent and VM verification; do not require a second local content-addressed world build

## 9. Credential-only A/B manifest signing (D11)

- [x] 9.1 Add conditional `LoadCredential = sysupdate_signing_key:<signingKeyFile>` to host `nixtache-ab-gc.service` and change its GPG import to `$CREDENTIALS_DIRECTORY/sysupdate_signing_key`; keep null-key signature cleanup and fail unit setup when a configured source is unreadable — extend `tests/runner.nix` and `tests/ab-existing.nix` to pin host/container credentials and reject the original path in the GC script
- [x] 9.2 Verify `ab-staging-vm` in KVM CI: retain-GC deletes old versions, regenerates and re-signs `SHA256SUMS`, and the detached signature verifies using only the unit credential; assert the service exposes `sysupdate_signing_key` in its credentials directory
- [x] 9.3 Update the `signingKeyFile` option description and `doc/technical_details/module-ci-wiring.md` with the host-GC and CI consumers, linked to `openspec/specs/runner/spec.md` — verify no maintained text describes direct host-path reads as the contract

## Workflow follow-up

- Archive the change after review (`/opsx-archive`), then verify the archived result.
- Companion change in `nixos-configuration`: the server migration walkthrough following the contract documented here (relabel, autoUpgrade off, two-phase flip, deploy-map entry `method = "ab-image"` with `gating = true`).

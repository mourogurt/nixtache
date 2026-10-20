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

**BLOCKED by the `lower-store-db` change** (created from this one's findings):
on a real appliance the lower store carries no nix DB, which breaks the
runner container's store in both modes (clone seeds from an empty DB;
overlay's `lower-store=daemon` self-references without a system daemon).
The suite exists (`tests/runner-store-swap-vm.nix`, wired into flake.nix
vmTests, deliberately absent from the CI matrix) and the module fix it
already drove — the host nspawn bind-path guarantee — is pinned by
tests/runner.nix ("appliance host"). The tasks below resume once
`lower-store-db` lands; note that change's own group 3 does the runner
container wiring, the suite unskip and the matrix join — what remains HERE
is verification + docs.

- [ ] 3.1 Create `tests/runner-store-swap-vm.nix` skeleton: `mkAppliance` embedding the runner container closure; a trivial build through the relocated store on v1 — verify the pre-swap build succeeds
- [ ] 3.2 Clone variant: swap, reboot → assert the re-clone is additive and a post-swap build succeeds (the nspawn bind-path guarantee already landed; the container appliance-mode wiring is `lower-store-db`'s group 3) — verify suite leg green and `nix flake check` passes
- [ ] 3.3 Overlay variant: swap, reboot → assert the merged view is coherent and a post-swap build succeeds — verify suite leg green
- [ ] 3.4 After `lower-store-db` wires the matrix: verify both suite modes report PASS in the full-matrix job log; note the runner-store-across-swaps behaviour under `doc/user_guide/ota.md` route 3 (gated self-update) with a link to `openspec/specs/runner/spec.md`; add the testing.md row — verify docs render

## 4. Overlay reconcile replay leg (D5)

- [x] 4.1 Extend `tests/overlay-nix-ota-invalid-vm.nix`: pre-swap `nix profile install` of the mock tool (hermetic, RAM-cheap, per the suite's realize rationale) → assert the capture records the per-user profile target in `roots.txt` — verify the pre-swap assertions pass
- [x] 4.2 Reconcile variant: assert the recorded profile installable is replayed post-swap (tool runs via the profile); `none`/`wipe` variants assert the negative (broken / gone) — verify all three variants green

## 5. Integration

- [x] 5.1 `nix flake check --show-trace --all-systems` green and `openspec validate server-ab-migration-prep --strict` green — verify both commands
- [ ] 5.2 Full `vmTests` matrix green on a KVM runner (manual dispatch of `vmtests.yml` with the full subset) — verify every suite, including the three new ones, reports PASS in the job log

## Workflow follow-up

- Archive the change after review (`/opsx-archive`), then verify the archived result.
- Companion change in `nixos-configuration`: the server migration walkthrough following the contract documented here (relabel, autoUpgrade off, two-phase flip, deploy-map entry `method = "ab-image"` with `gating = true`).

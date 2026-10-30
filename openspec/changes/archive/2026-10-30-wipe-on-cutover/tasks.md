# Tasks

## 1. Module: the cutover lifecycle unit

- [x] 1.1 In `modules/overlay-nix/default.nix` add the cutover detector using `/etc/image-version` and the lifecycle-only `/var/lib/nixtache/last-boot-image-version`: absent marker records a baseline without action, mismatch runs the policy, success writes the marker, reconcile failure leaves it pending; keep `lower-db-version` independent so the loader cannot consume retry — pin semantics in `tests/ab-contract.nix` and run that suite in CI
- [x] 1.2 Order `nixtache-overlay-lifecycle.service` by mode: `wipe` runs after `local-fs.target` (+ `zfs-mount.service` where needed) and before both `nixtache-lower-store-db-load.service` and `nix-daemon-overlay-mount.service`; `reconcile` runs after the lower-DB loader and after+requires the overlay mount, resolving roots live with no pre-captured `roots.txt` — pin ordering in `ab-contract`
- [x] 1.3 Add the D6 tmpfs path: detect `upperDir` with `findmnt -T` and clear stale upper-owned Nix state on every boot before the lower-DB loader reseeds and the overlay mounts; same-version persistent uppers remain untouched — add static ordering/configuration pins and the VM scenario in group 2
- [x] 1.4 Delete `nixtache-overlay-preupdate.service`, the `wants`/`after` wiring on `systemd-sysupdate.service` and the old reconcile-arming marker; rewrite the `upperOnUpdate` option description for cutover and tmpfs semantics — verify `ab-contract` asserts the old wiring is gone and `nix flake check` passes in CI

## 2. VM pins

- [x] 2.1 `tests/overlay-nix-ota-invalid-vm.nix` persistent-wipe variant, new pre-swap leg: with the tool realized into the upper, run `systemd-sysupdate` with NOTHING staged → assert the upper is intact and the tool still runs; add the same-version plain-reboot control with the same assertion — verify `overlay-nix-ota-invalid-wipe-vm` in KVM CI
- [x] 2.2 Same suite, rejected-update leg (wipe variant): stage a tampered payload (one byte flipped in the .raw) → sysupdate fails mid-install → assert the upper is intact and the machine runs the current slot; vacuum the partial instance before the normal flow resumes — verify the wipe variant passes
- [x] 2.3 Rework reconcile trigger pins for the unified mechanism: the pass runs at cutover boot after the lower-DB loader; the degraded variant retries through the unwritten lifecycle marker even after the loader wrote `lower-db-version` — verify `overlay-nix-ota-invalid-reconcile-vm` and `-reconcile-degraded-vm` in KVM CI
- [x] 2.4 Add a tmpfs same-version reboot leg: install a path, reboot, and assert stale DB/state is gone, the current lower DB is reseeded despite an unchanged image version, the merged store works, and the path can be realized again — verify `overlay-nix-ota-invalid-tmpfs-vm` in KVM CI
- [x] 2.5 Run the current `overlay-nix-ota-invalid` matrix (`-wipe`, `-reconcile`, `-reconcile-degraded`, `-tmpfs`) plus `overlay-nix-ab-swap-vm` and `overlay-nix-install-vm` in CI — verify all green without a local CA rebuild

## 3. Docs + integration

- [x] 3.1 Rewrite `doc/user_guide/overlay-nix.md` for cutover-time semantics, baseline/distinct markers, reconcile retry and tmpfs reset/reseed, with a link to `openspec/specs/overlay-nix/spec.md`; check `doc/user_guide/ota.md` for stale trigger phrasing and update `doc/technical_details/testing.md` — verify maintained docs match the module without local CA builds
- [x] 3.2 Run `openspec validate wipe-on-cutover --strict`, `openspec validate --specs --strict`, and the required checks in CI rather than duplicating the CA world locally
- [x] 3.3 Verify marker and ordering contracts against the landed lower-DB loader: `lower-db-version` remains independent, wipe precedes the loader, reconcile follows it, and a loader success cannot clear a pending reconcile retry — pin in `ab-contract` and the degraded VM leg

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied (coordinate archive order with `lower-store-db` — both touch `overlay-nix` capability deltas).
- Verify the archived result.

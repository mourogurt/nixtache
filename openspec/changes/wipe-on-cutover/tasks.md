# Tasks

## 1. Module: the cutover lifecycle unit

- [ ] 1.1 In `modules/overlay-nix/default.nix` add the cutover detector: `/etc/image-version` vs `/var/lib/nixtache/last-boot-image-version` on the persistent root — mismatch runs the configured action, success writes the marker, failure leaves the marker unwritten (reconcile retries next boot) — and rewire `nixtache-overlay-lifecycle.service` by mode: `wipe` → after `local-fs.target` (+ `zfs-mount.service` when `boot.zfs.enabled`), before `nix-daemon-overlay-mount.service`, wipe without the daemon stop/start dance; `reconcile` → after+requires the overlay mount (verifying against the bare lower must stay impossible), resolving roots live from the persistent root's gcroots/profile links (no pre-captured roots.txt) — verify with new pure-eval pins in `tests/ab-contract.nix` (unit ordering per mode, marker semantics) via `nix build .#checks.x86_64-linux.ab-contract`
- [ ] 1.2 Delete `nixtache-overlay-preupdate.service`, the `wants`/`after` wiring on `systemd-sysupdate.service` and the reconcile `ConditionPathExists` marker; rewrite the `upperOnUpdate` option description for cutover semantics (trigger-independent; what changed for `"wipe"`/`"reconcile"`) — verify ab-contract pins assert the preupdate unit is gone and `nix flake check` passes

## 2. VM pins

- [ ] 2.1 `tests/overlay-nix-ota-invalid-vm.nix` wipe variant, new pre-swap leg: with the tool realized into the upper, run `systemd-sysupdate` with NOTHING staged → assert the upper is intact and the tool still runs; extend the plain-reboot control with the same assert in wipe mode — verify `nix build .#vmTests.x86_64-linux.overlay-nix-ota-invalid-wipe-vm` and `-tmpfs-vm` pass
- [ ] 2.2 Same suite, rejected-update leg (wipe variant): stage a tampered payload (one byte flipped in the .raw) → sysupdate fails mid-install → assert the upper is intact and the machine runs the current slot; vacuum the partial instance before the normal flow resumes — verify the wipe variant passes
- [ ] 2.3 Rework the reconcile variants' trigger pins for the unified mechanism: no marker file; the pass runs at cutover boot; the degraded variant's retry is driven by the unwritten marker (a boot retries the pass) — verify `overlay-nix-ota-invalid-reconcile-vm` and `-reconcile-degraded-vm` pass
- [ ] 2.4 Run the whole `overlay-nix-ota-invalid` matrix (`none` — while it exists, `-wipe`, `-reconcile`, `-reconcile-degraded`, `-tmpfs`) plus `overlay-nix-ab-swap-vm` and `overlay-nix-install-vm` — verify all green (note: `lower-store-db` rewrites these suites for world A; whichever lands second rebases)

## 3. Docs + integration

- [ ] 3.1 Rewrite the `upperOnUpdate` lifecycle section in `doc/user_guide/overlay-nix.md` (cutover-time semantics, the marker, reconcile retry model, "update attempts never wipe") with a link to `openspec/specs/overlay-nix/spec.md`; check `doc/user_guide/ota.md`'s update/rollback table for stale trigger phrasing; update the suite descriptions in `doc/technical_details/testing.md` — verify the docs render and the stated behaviour matches the module
- [ ] 3.2 `nix flake check --show-trace --all-systems` and `openspec validate wipe-on-cutover --strict` both green
- [ ] 3.3 Marker sharing: confirm the `lower-store-db` lower-DB loader reads the same marker (whichever change lands second wires into it) — verify by reading the landed code of the other change and adjusting

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied (coordinate archive order with `lower-store-db` — both touch `overlay-nix` capability deltas).
- Verify the archived result.

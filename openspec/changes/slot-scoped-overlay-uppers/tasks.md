# Tasks

## 1. Physical slot identity and per-slot state

- [ ] 1.1 Implement early lower-partition discovery by GPT `PARTUUID`, the per-slot metaslot layout and stable runtime selection paths; extend `tests/overlay-nix.nix` and `tests/ab-contract.nix` for identity failure, path selection and unit ordering — verify both `nix build .#checks.x86_64-linux.overlay-nix` and `nix build .#checks.x86_64-linux.ab-contract` reports pass
- [ ] 1.2 Split host lower and upper metadata roles, point the lower-DB loader at the selected slot's lower-state, and select `/nix/var/nix`'s upper-owned state before the daemon starts; update first-boot and same-slot reboot coverage — verify `nix build .#vmTests.x86_64-linux.overlay-nix-vm` passes with lower paths valid and runtime installs persistent
- [ ] 1.3 Add idempotent migration of the legacy shared upper and Nix state into the active slot while preserving a recovery backup and marking the other slot unready; add a migration VM leg — verify previously installed tools work after migration and an induced migration failure leaves the legacy upper usable
- [ ] 1.4 Update `README.md`'s overlay overview, `doc/GLOSSARY.md` with the upper-metaslot term, and `doc/technical_details/lower-store-db.md` with the separate metadata roles and links to the canonical specs — verify the documents render and no text describes one shared database across slots

## 2. Host target preparation

- [ ] 2.1 Implement the shared target-preparation service with active/target safety checks, staging directories, atomic readiness metadata and the `wipe` policy; update `tests/overlay-nix-ab-swap-vm.nix` for target-only wiping — verify the new lower and clean target upper work while the pre-update upper remains byte-identical until cutover
- [ ] 2.2 Implement `reconcile` as snapshot-or-quiesced-clone of the current active metaslot followed by private-namespace target verification and repair; adapt `tests/overlay-nix-ota-invalid-vm.nix` and its reconcile variant — verify an old-lower dependency is fetched only into the target and the active DB/files are unchanged
- [ ] 2.3 Handle interrupted preparation, unavailable substituters, lower-dump checksum changes and physical-slot reuse through explicit unready generations and safe retry/discard behavior; extend the degraded and wipe/reconcile VM matrix — verify retries never mutate the active upper and a reused slot clones the latest active state rather than its stale prior state
- [ ] 2.4 Rewrite `doc/user_guide/overlay-nix.md` lifecycle sections for slot-scoped wipe/reconcile, storage/snapshot requirements, readiness, ephemeral descendants and migration, with canonical spec links — verify the documented recovery commands and paths match the implemented units and `doc/technical_details/testing.md` lists the changed matrix legs

## 3. Cutover, rollback and reboot integration

- [ ] 3.1 Wire target preparation into `nixtache-ab-update` and the stock reboot assessment, and gate host consumers plus `boot-complete.target` on selected-chain readiness; extend update and boot contract tests — verify failed preparation does not trigger reboot and an unrelated reboot into an unprepared UKI either recovers the target or remains unblessed
- [ ] 3.2 Add an upper-hosted critical-service rollback leg to `tests/ab-ota-rollback-vm.nix`, plus manual older-slot and same-version/different-upper selection coverage — verify failed new-slot health returns to the earlier working service and DB without a reverse wipe/reconcile, and `tests/ab-data-pool-vm.nix` asserts the same preservation rule on ZFS
- [ ] 3.3 Wire auto-update installation and deferred reboot through the shared helper, recording source generations and refreshing a stale reconcile target before a delayed cutover; extend `tests/auto-update.nix` and `tests/auto-update-vm.nix` — verify no-op polls skip preparation, immediate updates prepare once, and changes made during a reboot window are present in the target
- [ ] 3.4 Update `doc/user_guide/ota.md` failure, manual rollback and update-readiness behavior and `doc/technical_details/architecture.md` with the preparation/readiness ownership boundaries and canonical spec links — verify the guide distinguishes lower installation from upper readiness and no longer prescribes reverse upper reconciliation after rollback

## 4. Runner cascade and clone compatibility

- [ ] 4.1 Move runner overlay upper and upper-owned state into the selected metaslot, bind the selected host upper DB as its composite-lower metadata, and run runner target repair only after host target readiness; extend pure-eval runner contracts — verify `nix build .#checks.x86_64-linux.runner` and `nix build .#checks.x86_64-linux.ab-contract` pass with strict host-before-runner ordering
- [ ] 4.2 Extend `tests/runner-store-swap-vm.nix` with cascade isolation, failed-boot rollback and CI builds through both slot-specific runner uppers, and add the ephemeral-host/descendant-reset case — verify writes never leak into the inactive runner upper and rollback restores the earlier build store without reverse repair
- [ ] 4.3 Retain additive clone behavior and its single relocated store, then update the runner store documentation and `doc/technical_details/testing.md` for cascade-versus-clone semantics with canonical spec links — verify `nix build .#vmTests.x86_64-linux.runner-store-swap-clone-vm` still passes and the docs explain why clone mode has no per-slot copy

## 5. Integration verification

- [ ] 5.1 Reconcile all pure-eval expectations and option descriptions with the slot-scoped behavior, then run `nix flake check --show-trace --all-systems` and `openspec validate slot-scoped-overlay-uppers --strict` — verify every check and strict validation completes successfully
- [ ] 5.2 Run the full KVM `vmTests` matrix on a KVM-capable runner, including the updated smoke subset and every new migration, interruption, rollback and cascade leg — verify all suites report PASS and their current contracts are listed in `doc/technical_details/testing.md`

## Workflow follow-up

- Archive the change after review, then verify the archived result.

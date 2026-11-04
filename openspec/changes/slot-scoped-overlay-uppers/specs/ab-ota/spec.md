# Spec Delta

## MODIFIED Requirements

### Requirement: The trigger reboots only after a completed installation

The AB update trigger SHALL reboot only when `systemd-sysupdate` completed a lower installation, including a same-version rewrite with a changed lower checksum, and every enabled persistent upper layer has a prepared target metaslot. Empty, failed or unprepared updates SHALL leave the target running and surface the actual installation or preparation error.

#### Scenario: failed transfer does not reboot

- **WHEN** a trigger runs, the staged artifacts are unreachable, and sysupdate installs nothing
- **THEN** the target is not rebooted, no upper preparation starts, and the trigger reports the sysupdate failure

#### Scenario: successful install reboots into the new slot

- **WHEN** sysupdate installs a new version and the target upper metaslot is ready
- **THEN** the reboot leg starts, with the new slot artifacts and prepared target metadata present before reboot

#### Scenario: managed tmpfs update reboots without a persistent metaslot

- **WHEN** sysupdate installs a new version for an entirely ephemeral upper chain and the configured reboot window opens
- **THEN** installation and deferred reboot succeed without requiring or creating persistent upper state, and the new boot loads its own lower records after resetting the ephemeral chain

#### Scenario: failed upper preparation does not reboot

- **WHEN** the lower installation completes but target upper cloning, seeding or repair fails
- **THEN** the trigger reports the preparation failure and does not reboot while the active slot and upper remain available

#### Scenario: no completed installation does not reboot

- **WHEN** sysupdate completes without installing a lower, including an empty or no-op poll
- **THEN** no upper preparation or reboot is triggered

### Requirement: Slot swaps merge the new lower's records additively

During target preparation, the new slot's dump MUST merge additively into target lower-state, separately from writable upper databases. Stale cloned upper records MUST remain available for verification and repair, but neither lower nor upper target records MUST be merged into the active slot. Rollback MUST select the previous slot's preserved lower-state and upper databases together.

#### Scenario: Swap merges the new slot's records

- **WHEN** a cloned target metaslot is prepared for a newly installed lower
- **THEN** the new lower's records are imported into target lower-state, paths valid only in the new lower resolve through the composite store, and stale cloned upper records remain detectable until target verification

#### Scenario: Stale old-slot records remain detectable

- **WHEN** target verification runs after the new lower's dump was merged into target lower-state
- **THEN** stale records in cloned upper databases are reported in the target store, while the active slot's lower-state, upper databases and lifecycle markers remain unmodified

#### Scenario: Rollback reuses the preserved lower database

- **WHEN** the previous slot and its prepared metaslot boot again
- **THEN** its existing lower-state and upper validity records are selected together without an additive merge from the slot being left

## ADDED Requirements

### Requirement: Rollback restores the previous upper metaslot

A failed new boot MUST return to the previous blessed lower and its preserved upper chain. The rollback MUST NOT wipe, reclone or reconcile that previous upper merely because a different slot was booted.

#### Scenario: Failed upper-hosted service does not poison rollback

- **WHEN** a service from the new slot's upper fails boot health and boot counting exhausts
- **THEN** the previous slot boots with its earlier upper-hosted service, database and dependencies intact, allowing the previous boot health check to pass

#### Scenario: Manual rollback has the same preservation guarantee

- **WHEN** an operator selects an older prepared slot after running a newer one
- **THEN** the older upper chain resumes without incorporating changes made only to the newer slot's upper

### Requirement: Upper preparation is recoverable

Interrupting target upper preparation MUST NOT damage the active upper. An incomplete target MUST remain explicitly unready until a later preparation attempt validates the complete chain.

#### Scenario: Interrupted clone is retried safely

- **WHEN** copying, seeding or repairing the target upper is interrupted
- **THEN** the active upper remains usable and the next attempt discards or resumes only the incomplete target before validating it again

#### Scenario: Publication interruption is recoverable at every boundary

- **WHEN** interruption occurs after moving staging into a generation, after marking that generation ready, or after switching its current pointer
- **THEN** active state remains unchanged, and the next preparation either adopts the fully published ready generation or discards the incomplete one before publishing a coherent replacement

#### Scenario: Installation completed but preparation did not

- **WHEN** a lower image is fully installed but its upper metaslot is incomplete
- **THEN** the installation remains identifiable as needing upper preparation rather than being treated as a ready update

### Requirement: Unprepared upper chains cannot be blessed

On an appliance with persistent overlays, a newly selected slot MUST NOT reach boot-completion with an unready upper chain. Boot-time recovery MAY prepare only the selected target; failure MUST leave the boot unblessed so boot counting can return to the preserved slot.

#### Scenario: Unrelated reboot selects an unprepared installed image

- **WHEN** a new UKI was installed but its trigger did not reboot because upper preparation failed, and a later reboot selects that UKI
- **THEN** the upper chain is prepared successfully before boot-completion or the new boot remains unblessed and rolls back

#### Scenario: Module-managed upper consumers wait for readiness

- **WHEN** the host Nix daemon or runner overlay starts during a cutover boot
- **THEN** it starts only after its complete upper chain has been validated as ready

### Requirement: Repeated installations refresh the prepared target

Every completed installation MUST produce or validate preparation for the latest installed lower, even when an earlier installation is still awaiting reboot. Reboot MUST select the exact ready generation for that latest lower, not a stale earlier preparation.

#### Scenario: Two updates without an intermediate reboot select the second target

- **WHEN** v2 and then v3 are installed while v1 remains active and neither installation has rebooted
- **THEN** v3 receives a distinct ready generation whose image and lower checksum match v3, and the eventual reboot selects that generation without replacing it through boot recovery

#### Scenario: A successful preparation service remains rerunnable

- **WHEN** target preparation already succeeded for an earlier installed lower and a later lower is installed before reboot
- **THEN** starting preparation again performs the new target checks and publication instead of treating the earlier successful unit state as completion for the later lower

### Requirement: Target preparation is serialized per physical slot

Preparation and boot recovery for the same physical target slot MUST hold one common lock from staging cleanup through publication. A concurrent process MUST NOT remove or modify another process's staging tree.

#### Scenario: Concurrent installed preparations preserve staging ownership

- **WHEN** two installed-target preparation processes overlap for one inactive slot
- **THEN** the second waits for the target lock, the first staging tree survives until its own publication finishes, and the resulting current generation is ready

#### Scenario: Boot recovery shares the same lock

- **WHEN** installed-target preparation overlaps booted-target recovery for the selected slot
- **THEN** both paths use the same lock ordering and neither deletes the other's staging tree or exposes readiness before publication completes

### Requirement: Ready-generation retention is bounded

Successful publication MUST remove superseded ready generations according to a bounded retention policy while preserving the active and prepared generations needed for selection and rollback.

#### Scenario: Repeated preparation does not grow ready state without bound

- **WHEN** several reconcile preparations for one target slot complete successfully
- **THEN** the number of retained ready generations reaches a fixed bound, each rerun produces current metadata for the latest source, and no staging directories remain after publication

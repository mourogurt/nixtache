# Spec Delta

## MODIFIED Requirements

### Requirement: The trigger reboots only after a completed installation

The AB update trigger SHALL reboot only when `systemd-sysupdate` completed a new installation and every enabled persistent upper layer has a prepared target metaslot. Empty, failed or unprepared updates SHALL leave the target running and surface the actual installation or preparation error.

#### Scenario: failed transfer does not reboot

- **WHEN** a trigger runs, the staged artifacts are unreachable, and sysupdate installs nothing
- **THEN** the target is not rebooted, no upper preparation starts, and the trigger reports the sysupdate failure

#### Scenario: successful install reboots into the new slot

- **WHEN** sysupdate installs a new version and the target upper metaslot is ready
- **THEN** the reboot leg starts, with the new slot artifacts and prepared target metadata present before reboot

#### Scenario: failed upper preparation does not reboot

- **WHEN** the lower installation completes but target upper cloning, seeding or repair fails
- **THEN** the trigger reports the preparation failure and does not reboot while the active slot and upper remain available

#### Scenario: no installed version does not reboot

- **WHEN** sysupdate completes without installing a newer version
- **THEN** no upper preparation or reboot is triggered

### Requirement: Slot swaps merge the new lower's records additively

During target preparation, the new slot's dump MUST merge additively into the target upper database. Stale cloned records MUST remain available for verification and repair, but MUST NOT be merged into the active slot's database. A rollback MUST reuse the previous slot's preserved database rather than remerging it for the return trip.

#### Scenario: Swap merges the new slot's records

- **WHEN** a cloned target metaslot is prepared for a newly installed lower
- **THEN** the new lower's records are imported into the target database, paths valid only in the new lower resolve, and stale cloned records remain detectable until target verification

#### Scenario: Stale old-slot records remain detectable

- **WHEN** target verification runs after the new lower's dump was merged into a cloned target database
- **THEN** stale old-lower records are reported in the target store, while the active slot's database and lifecycle markers remain unmodified by target-only records

#### Scenario: Rollback reuses the preserved lower database

- **WHEN** the previous slot and its prepared metaslot boot again
- **THEN** its existing lower and upper validity records are selected together without an additive merge from the slot being left

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

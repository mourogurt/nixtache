# ab-ota Specification

## Purpose

The OTA (A/B image) update route end to end: how an appliance receives its
first image (fresh disk or existing machine), how CI-, timer- and
idle-gate-driven updates land in the inactive slot, and how faulty updates
are detected, skipped or rolled back. Complements the deploy-transport
requirements already owned by the `direct-deploy` and `deploy-user`
capabilities (per-target failure isolation, reboot-after-write, slot labels,
size-mismatch handling, protocol drift).

## Requirements

### Requirement: Fresh-disk first deploy produces an OTA-manageable appliance

Installing nixtache's A/B appliance onto a bare disk (nixos-anywhere with a
declarative disk layout: ESP + two nix-store slots + persistent root) MUST
yield a system that boots the installed slot and is immediately manageable
by the OTA route: the first staged update is pulled, written to the inactive
slot and booted, with signature verification active when a public key is
configured.

#### Scenario: anywhere-installed appliance receives its first OTA update

- **WHEN** the appliance is installed via nixos-anywhere with the A/B disk
  layout and boots the installed slot, and a signed v2 update is staged on
  the deployer
- **THEN** the appliance pulls v2, writes the inactive slot, reboots into
  v2 (verified by the image-version marker), and the previous slot remains
  intact as rollback

#### Scenario: Unsigned update is rejected on first OTA

- **WHEN** the appliance carries a verification public key
  (`Transfer.Verify=yes`) and the staged manifest is unsigned or signed with
  a wrong key
- **THEN** the update is refused, the slots are untouched and the appliance
  keeps running the installed version

### Requirement: Existing-disk first deploy refuses safely without space or consent

Provisioning A/B slots on a machine that already runs a system MUST either
lay out the slots when `autoInit` is enabled and free space suffices, or
fail with an actionable message — never silently skip or truncate slots.

#### Scenario: Not enough free space for two slots

- **WHEN** `ab.partitions` provisioning runs with `autoInit = true` on a
  disk whose free space is below twice the configured slot size
- **THEN** provisioning fails with a message naming the deficit and the
  available remedies (shrink slotSize, free space, second disk, manual
  provisioning) — no partition is created

#### Scenario: Slots missing and autoInit disabled

- **WHEN** provisioning runs on a disk without A/B slots and
  `autoInit = false`
- **THEN** the provisioning unit fails with a message pointing at
  `autoInit = true` (or manual setup); the machine keeps booting its
  existing system unchanged

### Requirement: OTA artifact versioning is assigned at CI runtime

The OTA deploy path MUST NOT rely on declarative image versions: the
version is assigned at deploy time (an explicit override when provided,
otherwise a UTC calendar version), written to the repository's version file
BEFORE the image build, and the same value MUST flow unchanged into the
staged artifact filenames, the signed manifest and the target's slot label.

#### Scenario: Explicit version override flows end to end

- **WHEN** the deploy action runs with an explicit version override set in
  the job environment
- **THEN** the repository's image-version file contains exactly that value
  before `nix build` runs, and the staged artifacts and manifest carry
  filenames stamped with it; the target's inactive slot is relabelled with
  the same version

#### Scenario: Missing override falls back to a calendar version

- **WHEN** the deploy action runs without an explicit version override
- **THEN** a UTC calendar version (YYYYMMDDhhmmss) is assigned, written to
  the version file, and stamped onto the staged artifacts

### Requirement: Same-version staging is a no-op

Staging an OTA update whose version does not exceed the version already
installed in the active slot MUST leave the target unchanged: no slot is
written, no reboot is triggered, and the deploy pipeline reports that
nothing was installed rather than failing.

#### Scenario: Re-deploying the running version installs nothing

- **WHEN** the target's active slot is version N and the staged artifacts
  are also version N
- **THEN** the update mechanism installs nothing, the inactive slot and the
  boot entries are untouched, and the trigger completes without error

### Requirement: A failed new boot rolls back to the previous slot

When a new image exhausts its boot attempts before boot-completion, the
bootloader MUST fall back to the previous blessed entry and MUST NOT select
the failed image again automatically. Because update-instance selection is
version-driven, recovery from rollback MUST remove the failed version while
preserving the running oldest slot before another update (see the OTA guide).

#### Scenario: Broken image exhausts its tries

- **WHEN** an update installs an image whose boot never reaches
  boot-complete.target and the boot-counting tries are exhausted
- **THEN** the machine boots the previous blessed entry (the running
  system is the pre-update version), and the failed entry carries no
  remaining tries

#### Scenario: Rollback leaves a stable, update-aware machine

- **WHEN** the rollback described above happens
- **THEN** the previous version's slot content is intact, the machine is
  stable on it, and the update machinery remains functional (update
  listing works; the timer is active)

#### Scenario: Recovery permits a safe subsequent update

- **WHEN** the failed version is removed while preserving the running oldest
  slot and a newer fixed image is staged
- **THEN** the next update writes only an inactive slot and never overwrites
  the running slot, after which the fixed image can boot and be blessed

### Requirement: An interrupted update is recoverable

An update interrupted while writing the inactive slot (power loss, reset,
cancelled transfer) MUST NOT corrupt the running system: the active slot is
never the write target, and the half-written inactive slot is never booted.
Recovery MUST be explicit and safe: the update mechanism refuses to
re-install a partially-installed version until the partial instance is
vacuumed, and a vacuum followed by the next update rewrites the inactive
slot completely before it can be booted.

#### Scenario: Half-written inactive slot does not boot

- **WHEN** an update is interrupted mid-write and the machine reboots
  before any new boot entry was selected
- **THEN** the machine boots the existing (active) system; the partially
  written slot is never chosen by the bootloader

#### Scenario: Partial instance is refused until vacuumed

- **WHEN** an update is attempted while the selected version is already
  partially installed
- **THEN** the update mechanism refuses with a message naming the vacuum
  remedy instead of writing on top of the partial slot

#### Scenario: Vacuum and retry repairs the partial slot

- **WHEN** the partial instance is vacuumed and a new update is staged
- **THEN** the update mechanism rewrites the inactive slot completely and
  the update proceeds normally

### Requirement: A live-deployed target can move to the OTA route

A machine previously deployed via the live path (`method = "live"`) MUST be
migratable to the OTA route in a controlled order: A/B slots are provisioned
on free space, the first OTA image is installed and blessed while the live
generation remains bootable as a fallback, and the deploy map entry flips to
`method = "ab-image"` without a window in which the machine is unmanaged.

#### Scenario: Migration preserves a working fallback

- **WHEN** a live-deployed target provisions A/B slots and receives its
  first OTA image
- **THEN** the previously active live generation remains available as a
  boot fallback until the first OTA boot is blessed, and the next deploy
  run delivers an image update (not a live closure)

#### Scenario: A staged image never cuts over while the legacy default pin stands

- **WHEN** an image is staged onto a migrated machine whose ESP `loader.conf`
  still carries the live-era pin (`default nixos-*`, or an exact-entry
  `default`/`preferred` written by NixOS's systemd-boot installer), and the
  machine reboots
- **THEN** the pre-migration entry boots — the staged UKI is not selected;
  cutover requires the documented one-time arming step (removing the
  live-era `default`/`preferred` lines) before or with the first apply

#### Scenario: Once armed, the newest image is selected

- **WHEN** the ESP `loader.conf` no longer pins the live-era default (the
  `default`/`preferred` lines removed — a UKI-only default glob MUST NOT be
  used: default-pattern matching ignores boot assessment and would reselect
  an exhausted entry) and a newer image is staged, and the machine reboots
- **THEN** systemd-boot's entry sort selects the staged UKI (its IMAGE_ID
  sort-key orders before the legacy `nixos` sort-key); if its tries exhaust
  without blessing, the sorted-first good entry (the previous blessed UKI,
  else the legacy generation) boots instead — subsequent updates flow
  without further ESP edits

### Requirement: The first OTA boot requires the image mount contract

Because provisioning creates only the two nix-store slots, the pre-existing
disk MUST satisfy the image's mount contract before the first OTA boot: the
partitions serving `/` and the ESP are reachable under the device identifiers
the image was built with (the default GPT partlabels `root` and `boot`, or
consumer-overridden `fileSystems` devices baked into the image's initrd).

#### Scenario: Legacy partition labels roll back safely

- **WHEN** a migrated disk's partitions do not satisfy the image's mount
  contract (e.g. the GPT partlabels `root`/`boot` are absent) and the first
  staged OTA image is selected at boot
- **THEN** the boot never reaches boot-completion, boot counting exhausts
  the new entry's tries, and the machine boots the pre-migration entry
  again with the update machinery still functional — no brick, no silent
  state

#### Scenario: Honoured mount contract cuts over

- **WHEN** the disk satisfies the image's mount contract (partitions
  relabeled to `root`/`boot`, or `fileSystems` overrides baked into the
  image) and the first OTA image is staged and applied
- **THEN** the machine boots the staged image, the boot is blessed, and the
  pre-migration loader entries remain on the ESP as bootable fallback

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

- **WHEN** sysupdate completes without installing a lower and no earlier installation has incomplete upper preparation
- **THEN** no upper preparation or reboot is triggered

### Requirement: Slot filesystem variants are boot-equivalent

Every slot filesystem variant the ab-image module can produce — at minimum
squashfs and erofs — SHALL yield an appliance that boots to
`boot-complete.target` with `/nix/store` mounted and readable. A variant
that builds but cannot boot is a defect, not a supported mode.

#### Scenario: erofs appliance boots

- **WHEN** an appliance image is built with an erofs nix-store partition
  and booted in a VM
- **THEN** the kernel console produces boot output, the system reaches
  `boot-complete.target`, and `/nix/store` is mounted readable from the
  erofs partition

#### Scenario: squashfs appliance boots

- **WHEN** an appliance image is built with a squashfs nix-store partition
  and booted in a VM
- **THEN** the system reaches `boot-complete.target` and `/nix/store` is
  mounted readable from the squashfs partition

### Requirement: The appliance image ships a store database dump for the slot closure

The image build MUST generate `nix-store --load-db`-compatible validity records (path, narHash, narSize, deriver, references) covering the entire toplevel closure of the slot. NAR hashes and sizes MUST describe the exact staged store tree used to populate the slot, and the tree and dump MUST come from one immutable paired snapshot. The dump MUST ship inside the image artifact set so every boot of that slot can load it without network or build machinery.

#### Scenario: Image carries a complete closure dump

- **WHEN** an appliance image is built
- **THEN** the image contains a validity-record dump whose entries cover exactly the running toplevel's closure, each record carrying path, narHash, narSize, deriver and references

#### Scenario: Records describe the staged bytes

- **WHEN** the slot snapshot contains an input-addressed path whose source registration differs from the staged content
- **THEN** the shipped record carries the NAR hash and size computed from the staged content, and copying that path with its shipped record succeeds

#### Scenario: Store content and records cannot come from different realisations

- **WHEN** an image is assembled from cached or locally built inputs
- **THEN** the slot filesystem source and its lower database are taken from the same paired snapshot rather than independently selected dump and tree artifacts

#### Scenario: Dump artifact is reused across unchanged rebuilds

- **WHEN** two image builds share the same toplevel closure
- **THEN** the paired snapshot is built once and reused, so unchanged rebuilds do not recompute the tree or its narHash/narSize records

### Requirement: Appliance images support input-addressed closures

An appliance image built from an ordinary input-addressed nixpkgs evaluation MUST produce a bootable slot with valid lower-store records. The image build and its runtime consumers MUST NOT require `contentAddressedByDefault` or the `ca-derivations` experimental feature.

#### Scenario: Ordinary input-addressed evaluation builds an appliance

- **WHEN** an appliance is evaluated without `contentAddressedByDefault` and with CA derivation support disabled
- **THEN** the image build succeeds without a CA-configuration assertion, and the shipped lower paths resolve through standard Nix tooling after the dump is loaded

#### Scenario: Input-addressed lower records support closure copying

- **WHEN** a consumer copies the complete closure from the shipped slot store and snapshot-derived database
- **THEN** Nix verifies every copied NAR against its shipped hash and completes without requiring CA realisations

### Requirement: Top-level symlink closure paths ship faithfully

The image build MUST ship a toplevel-closure path that is itself a symlink as that symlink — never as its target's content. The imaging mechanism MUST dereference at most the single copy source it is pointed at and preserve the type of every entry inside it, so the shipped store filesystem matches the snapshot-derived database records for supported closure compositions.

#### Scenario: A symlink store path ships as a symlink

- **WHEN** the toplevel closure contains a store path that is itself a symlink to another store path
- **THEN** the image's store filesystem contains it as a symlink to its recorded target, standard nix tooling resolves its validity from the shipped database, and copying from the image verifies its hash without mismatch

#### Scenario: A closure without symlink paths builds unchanged

- **WHEN** the toplevel closure contains no top-level symlink paths
- **THEN** the image builds exactly as before the faithful-imaging change, with the same store content and equivalent validity records

### Requirement: Max-disk mode fills the root partition, not the ESP

When the image is built at a fixed total size (`diskSize` set), the leftover space MUST land on the root partition: the ESP and both A/B slots keep fixed sizes (the ESP claims no proportional share), and the distribution MUST be deterministic — identical inputs produce an identical partition layout.

#### Scenario: Max-disk layout gives the leftover space to root

- **WHEN** an image is built with `diskSize` set
- **THEN** the ESP stays at its pinned size and the root partition takes the space left by the ESP and the fixed slots

#### Scenario: The ESP minimum is explicit

- **WHEN** the ESP partition size is configured below the builder's enforced vfat minimum (260MiB at 4K filesystem sectors)
- **THEN** the effective configuration carries the enforced minimum explicitly (no silent divergence between the configured and shipped sizes)

### Requirement: A boot-time loader seeds the lower store database when missing or stale

A boot-time oneshot MUST load the running slot's dump into `/nix/var/nix/db` whenever the database is absent (first boot, or after an upper-layer wipe cleared it) or the recorded image-version marker differs from the running image version (a slot swap happened). Loading MUST be additive: existing records are kept.

#### Scenario: First boot seeds the database

- **WHEN** the appliance boots with no store database present
- **THEN** the loader imports the running slot's dump, and a lower store path resolves through standard nix tooling (`nix path-info`) without any manual seeding

#### Scenario: No-op when the database matches the running image

- **WHEN** the appliance reboots without an update and the version marker matches the running image version
- **THEN** the loader performs no import and the database is unchanged

#### Scenario: After a wipe the database is re-seeded

- **WHEN** an upper-layer wipe removed the store database and the appliance boots
- **THEN** the loader re-imports the running slot's dump before nix-dependent services operate on the store

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

#### Scenario: Same-version slots retain distinct generation artifacts

- **WHEN** two physical slots contain the same image version with different lower dumps or topology descriptors
- **THEN** each prepared generation selects its own generation-owned dump and descriptor, and installing or booting the other slot neither overwrites that identity nor triggers reverse preparation

### Requirement: Storage outside the A/B slots survives updates

Consumer filesystems outside the A/B slots (data pools or disks holding
service state) MUST be untouched by updates: an update writes only the
inactive nix-store slot and the ESP, and every boot — on either slot,
including after a rollback — imports and serves that storage. Writable
overlay upper layers placed on such storage MUST come up ordered after the
storage mount and keep working across swaps where the filesystem supports
OverlayFS uppers (ZFS ≥ 2.2).

#### Scenario: Pool imports and serves state after a swap

- **WHEN** an appliance with a ZFS pool outside the slots holding service
  state installs an update and boots the new slot
- **THEN** the pool imports, previously written state is readable, and
  services backed by it start without manual repair

#### Scenario: Rollback keeps the pool importable

- **WHEN** the appliance rolls back to the previous slot (whose ZFS/kernel
  may be older) and no pool upgrade (`zpool upgrade`) was performed
- **THEN** the pool still imports and serves state — slot version drift
  does not wedge consumer data

#### Scenario: Overlay upper on the pool

- **WHEN** an overlay-nix upper layer is placed on a dataset of such a pool
  (ZFS ≥ 2.2) with `upperOnUpdate = "reconcile"` and a substituter retaining
  the old closure
- **THEN** the merged store mounts after the pool import, runtime installs
  work before the swap, and after the swap the overlay remounts over the new
  lower and reconciles the preserved upper back to a working state

### Requirement: Slot sizes are absolute and deterministic

`services.nixtache.ab-image.storeSize` and
`services.nixtache.deploy-target.ab.partitions.slotSize` MUST accept only
absolute sizes, so one configuration produces the same slot sizes on every
machine. Percentage values MUST fail evaluation with an actionable message;
the image build MUST NOT substitute a fallback size. When both modules are
enabled, their absolute sizes MUST match.

#### Scenario: Percentage slot size is rejected

- **WHEN** either size option is set to a percentage such as `"25%"`
- **THEN** evaluation fails and asks for an explicit absolute size instead of
  resolving it against whichever disk happens to be attached

#### Scenario: Co-imported image and provision sizes agree

- **WHEN** both modules are enabled with different explicit absolute sizes
- **THEN** evaluation fails with a size-mismatch error; equal absolute values
  produce identical image and provision sizes

#### Scenario: Low-space remedy uses the deterministic size

- **WHEN** provisioning lacks space for two absolute-size slots
- **THEN** the error includes reducing `slotSize` among the remedies alongside
  freeing space, adding a disk and manual provisioning

### Requirement: Timer-driven OTA observes completed installs and correct reboot windows

The A/B auto-update poll MUST wait for the version-appropriate sysupdate unit
to finish before deciding whether an image installed:
`systemd-sysupdate-update.service` on systemd 262 and newer, and
`systemd-sysupdate.service` on older releases. Reboot markers and reboot
actions MUST be based on that completed result. A non-cross-midnight reboot window is
start-inclusive and end-exclusive; a cross-midnight window wraps over midnight,
including for persistent timer catch-up.

#### Scenario: Reboot decision waits for installation

- **WHEN** sysupdate is still writing an image while the poll starts it
- **THEN** the poll waits for completion before setting `installed` or a pending
  reboot marker, and a no-op result does not trigger either one

#### Scenario: Non-midnight window bounds

- **WHEN** a reboot is pending for a `02:00`–`05:00` window
- **THEN** times before 02:00 and at/after 05:00 do not reboot, while 02:00 and
  times inside the window do

#### Scenario: Cross-midnight window bounds

- **WHEN** a reboot is pending for a `23:00`–`02:00` window
- **THEN** 23:00 through 23:59 and 00:00 through 01:59 are inside the window,
  while 02:00 and later daytime times are outside

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

Every completed installation MUST produce or validate preparation for the latest installed lower, even when an earlier installation is still awaiting reboot. Reboot MUST select the exact ready generation for that latest lower, not a stale earlier preparation. Making room for a later installation MUST NOT vacuum the running image's lower partition or associated ESP resources before cutover.

#### Scenario: Two updates without an intermediate reboot select the second target

- **WHEN** v2 and then v3 are installed while v1 remains active and neither installation has rebooted
- **THEN** v3 receives a distinct ready generation whose image and lower checksum match v3, and the eventual reboot selects that generation without replacing it through boot recovery

#### Scenario: Repeated installation preserves the running image resources

- **WHEN** v2 and then v3 are installed while v1 remains active
- **THEN** v1's lower partition, lower dump, topology descriptor and boot resources remain available throughout installation and preparation

#### Scenario: A successful preparation service remains rerunnable

- **WHEN** target preparation already succeeded for an earlier installed lower and a later lower is installed before reboot
- **THEN** starting preparation again performs the new target checks and publication instead of treating the earlier successful unit state as completion for the later lower

### Requirement: Incomplete upper preparation remains recoverable

An installed lower whose upper preparation failed MUST retain a durable preparation requirement until installed or boot recovery succeeds. A later poll that installs nothing MUST retry only when that requirement exists and sysupdate confirms a target awaiting cutover; a clean no-op MUST remain inert.

#### Scenario: A no-op poll recovers incomplete preparation

- **WHEN** an earlier lower installation completed but its upper preparation failed, and a later sysupdate poll installs nothing while that target still awaits cutover
- **THEN** the durable preparation requirement remains pending, preparation retries once, and success applies the normal reboot policy; without that pending requirement the no-op poll neither prepares nor reboots

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

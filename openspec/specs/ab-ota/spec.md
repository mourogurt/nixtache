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

### Requirement: The trigger reboots only after a completed installation

The AB update trigger's reboot leg SHALL reboot the target only when
`systemd-sysupdate` reported a successful installation on that trigger. When
the update installed nothing — because nothing was staged, the transfer
failed, or verification rejected the payload — the trigger SHALL leave the
target running and surface the sysupdate failure, so callers see the actual
error instead of a reboot followed by timeouts on artifacts that never
landed.

#### Scenario: failed transfer does not reboot

- **WHEN** a trigger runs, the staged v2 artifacts are unreachable, and
  sysupdate installs nothing
- **THEN** the target is not rebooted and the trigger reports the sysupdate
  failure

#### Scenario: successful install reboots into the new slot

- **WHEN** sysupdate reports `Successfully installed` for a new version
- **THEN** the reboot leg reboots the target and the new slot's marker
  artifacts (slot `.efi`, relabelled partition) are present before the
  reboot begins

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

# Spec Delta

## MODIFIED Requirements

### Requirement: A live-deployed target can move to the OTA route

A machine previously deployed via the live path (`method = "live"`) MUST be
migratable to the OTA route in a controlled order: A/B slots are provisioned
on free space, the first OTA image is installed and blessed while the live
generation remains bootable as a fallback, and the deploy map entry flips to
`method = "ab-image"` without a window in which the machine is unmanaged.
Because provisioning creates only the two nix-store slots, the pre-existing
disk MUST satisfy the image's mount contract before the first OTA boot: the
partitions serving `/` and the ESP are reachable under the device identifiers
the image was built with (the default GPT partlabels `root` and `boot`, or
consumer-overridden `fileSystems` devices baked into the image's initrd).

#### Scenario: Migration preserves a working fallback

- **WHEN** a live-deployed target provisions A/B slots and receives its
  first OTA image
- **THEN** the previously active live generation remains available as a
  boot fallback until the first OTA boot is blessed, and the next deploy
  run delivers an image update (not a live closure)

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

## ADDED Requirements

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

The A/B auto-update poll MUST wait for `systemd-sysupdate.service` to finish
before deciding whether an image installed. Reboot markers and reboot actions
MUST be based on that completed result. A non-cross-midnight reboot window is
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

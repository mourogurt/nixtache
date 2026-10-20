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
  cutover requires the documented one-time arming step (pointing the
  `loader.conf` default at the image's UKI pattern) before or with the first
  apply

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
  (ZFS ≥ 2.2)
- **THEN** the merged store mounts after the pool import, runtime installs
  work before the swap, and after the swap the overlay remounts over the
  new lower with the upper layer intact

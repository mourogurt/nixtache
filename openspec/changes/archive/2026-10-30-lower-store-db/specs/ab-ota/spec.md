# Spec Delta

## ADDED Requirements

### Requirement: The appliance image ships a store database dump for the slot closure

The image build MUST generate `nix-store --load-db`-compatible validity records (path, narHash, narSize, deriver, references) covering the entire toplevel closure of the slot, and MUST ship the dump inside the image so every boot of that slot can load it without network or build machinery.

#### Scenario: Image carries a complete closure dump

- **WHEN** an appliance image is built
- **THEN** the image contains a validity-record dump whose entries cover exactly the running toplevel's closure, each record carrying path, narHash, narSize, deriver and references

#### Scenario: Dump artifact is reused across unchanged rebuilds

- **WHEN** two image builds share the same toplevel closure
- **THEN** the dump artifact is built once and reused (cached per toplevel), so unchanged rebuilds do not recompute narHash/narSize

### Requirement: Appliance image closures are content-addressed

The appliance image evaluation MUST build its toplevel closure with nixpkgs content-addressing enabled (`config.contentAddressedByDefault`), so every shipped path's database record is content-true (`ca:fixed:r:`) and the dump is the registered validity records verbatim, without re-hashing. The image build MUST fail with actionable guidance when the evaluation's nixpkgs is not content-addressed.

#### Scenario: Non-CA image evaluation fails the build

- **WHEN** an appliance image is built whose nixpkgs evaluation does not enable `contentAddressedByDefault`
- **THEN** the build fails with an error naming the missing nixpkgs configuration and how to enable it

#### Scenario: The dump is the registered validity records

- **WHEN** a content-addressed appliance image is built
- **THEN** the shipped dump equals the closure's registered validity records (no per-path re-hashing at dump time), and a shipped path reports its `ca:fixed:r:` marker through standard nix tooling (`nix path-info`)

### Requirement: Top-level symlink closure paths ship faithfully

The image build MUST ship a toplevel-closure path that is itself a symlink as that symlink — never as its target's content. The imaging mechanism MUST dereference at most the single copy source it is pointed at and preserve the type of every entry inside it, so the shipped store filesystem matches the database records for any closure composition (input-addressed or content-addressed alike; standard closures contain such paths, e.g. multi-output `man`/`doc` symlinks).

#### Scenario: A symlink store path ships as a symlink

- **WHEN** the toplevel closure contains a store path that is itself a symlink to another store path
- **THEN** the image's store filesystem contains it as a symlink to its recorded target, standard nix tooling resolves its validity from the shipped database, and copying from the image verifies its hash without mismatch

#### Scenario: A closure without symlink paths builds unchanged

- **WHEN** the toplevel closure contains no top-level symlink paths
- **THEN** the image builds exactly as before the faithful-imaging change (same content, same records)

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

After an OTA slot swap, the new slot's dump MUST be merged into the existing database additively; stale records of the previous slot MUST NOT be deleted by the loader — they remain detectable by store verification and healable by the overlay reconcile pass.

#### Scenario: Swap merges the new slot's records

- **WHEN** the appliance boots into a swapped slot whose image version differs from the recorded marker
- **THEN** the new slot's records are imported, the marker is updated to the running version, and paths valid only in the new lower resolve through nix tooling

#### Scenario: Stale old-slot records remain detectable

- **WHEN** store verification runs after a swap whose old-lower paths are absent from the merged store
- **THEN** the stale entries are reported as dangling (not silently treated as healthy), and the reconcile pass can drop and repair them

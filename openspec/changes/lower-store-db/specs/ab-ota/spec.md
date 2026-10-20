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

### Requirement: A top-level symlink closure path fails the image build

The image build MUST fail listing the offending paths when any toplevel-closure path is a top-level symlink: the image builder resolves top-level symlinks when imaging, which would ship content contradicting the path's content-addressed hash.

#### Scenario: A top-level symlink closure path fails the build

- **WHEN** the toplevel closure contains a store path that is itself a symlink
- **THEN** the image build fails listing the offending path(s), instead of shipping content that contradicts its database record

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

# Spec Delta

## MODIFIED Requirements

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

### Requirement: Top-level symlink closure paths ship faithfully

The image build MUST ship a toplevel-closure path that is itself a symlink as that symlink — never as its target's content. The imaging mechanism MUST dereference at most the single copy source it is pointed at and preserve the type of every entry inside it, so the shipped store filesystem matches the snapshot-derived database records for supported closure compositions.

#### Scenario: A symlink store path ships as a symlink

- **WHEN** the toplevel closure contains a store path that is itself a symlink to another store path
- **THEN** the image's store filesystem contains it as a symlink to its recorded target, standard nix tooling resolves its validity from the shipped database, and copying from the image verifies its hash without mismatch

#### Scenario: A closure without symlink paths builds unchanged

- **WHEN** the toplevel closure contains no top-level symlink paths
- **THEN** the image builds exactly as before the faithful-imaging change, with the same store content and equivalent validity records

## ADDED Requirements

### Requirement: Appliance images support input-addressed closures

An appliance image built from an ordinary input-addressed nixpkgs evaluation MUST produce a bootable slot with valid lower-store records. The image build and its runtime consumers MUST NOT require `contentAddressedByDefault` or the `ca-derivations` experimental feature.

#### Scenario: Ordinary input-addressed evaluation builds an appliance

- **WHEN** an appliance is evaluated without `contentAddressedByDefault` and with CA derivation support disabled
- **THEN** the image build succeeds without a CA-configuration assertion, and the shipped lower paths resolve through standard Nix tooling after the dump is loaded

#### Scenario: Input-addressed lower records support closure copying

- **WHEN** a consumer copies the complete closure from the shipped slot store and snapshot-derived database
- **THEN** Nix verifies every copied NAR against its shipped hash and completes without requiring CA realisations

## REMOVED Requirements

### Requirement: Appliance image closures are content-addressed

**Reason**: Floating CA derivation behavior is experimental and is not necessary to establish coherence between a slot's staged store tree and its database.

**Migration**: Build new appliance images with ordinary input-addressed nixpkgs evaluation and snapshot-derived records. Existing CA-to-IA deployment migration is outside this change because no deployed CA appliances exist.

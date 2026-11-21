# Spec Delta

## ADDED Requirements

### Requirement: Full Nix surface over an input-addressed read-only store

With the overlay enabled on an A/B appliance, Nix MUST be usable through the standard system daemon: ad-hoc realize, run, shell, build, profile install and garbage collection all operate on the merged view. Writes for paths not already valid in the lower store MUST land in the configured upper layer without mutating the lower image, and runtime evaluation MUST work over input-addressed lower closures without requiring `ca-derivations`.

#### Scenario: Install a package at runtime on an appliance

- **WHEN** a package is realized (or profile-installed) from a configured substituter on an appliance whose `/nix/store` is a read-only image
- **THEN** the package's store paths not already valid in the lower store land under the configured upper layer, the binary runs through the merged `/nix/store`, and the lower layer's content is byte-identical to the image

#### Scenario: Runtime evaluation works over the input-addressed closure

- **WHEN** a profile install evaluates nixpkgs on an appliance whose lower closure is input-addressed and CA derivation support is disabled
- **THEN** the evaluation and install complete against the merged view, and paths already valid in the lower store retain their input-addressed identities

#### Scenario: The overlay is mounted before the daemon serves requests

- **WHEN** the appliance boots
- **THEN** the OverlayFS at `/nix/store` (lower = image partition, upper = configured upper layer) is active before the nix daemon serves any request, so every nix command observes the merged view

## REMOVED Requirements

### Requirement: Full nix surface over a read-only store

**Reason**: The previous requirement made CA derivation support part of the basic overlay contract. The replacement retains the complete Nix surface over an input-addressed lower closure without that dependency.

**Migration**: Use snapshot-derived input-addressed appliance images and ordinary runtime evaluation. Existing CA appliance migration is outside this change because no deployed CA appliances exist.

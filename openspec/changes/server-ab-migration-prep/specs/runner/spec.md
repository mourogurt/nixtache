# Spec Delta

## ADDED Requirements

### Requirement: The runner store survives OTA slot swaps

On an appliance runner host (`method = "ab-image"`), the runner's relocated
store MUST remain functional across OTA slot swaps without manual repair:
in clone mode the post-swap re-clone is additive and keeps serving builds;
in overlay mode the merged view remounts coherently over the new lower.
The runner container's wiring MUST NOT assume a host nix daemon or host
store database on an appliance (whose host has nix disabled).

#### Scenario: Clone mode keeps building after a swap

- **WHEN** the runner uses a cloned relocated store, an OTA update swaps
  the active slot, and the machine reboots into the new image
- **THEN** the re-clone after the swap is additive (previously cloned paths
  kept, new lower paths added) and a CI build through the relocated store
  succeeds

#### Scenario: Overlay mode stays coherent after a swap

- **WHEN** the runner uses an overlay relocated store, an OTA update swaps
  the active slot, and the machine reboots into the new image
- **THEN** the overlay remounts over the new lower and a CI build through
  the relocated store succeeds

#### Scenario: No host-daemon assumptions on an appliance

- **WHEN** the runner container runs on an appliance whose host has nix
  disabled
- **THEN** the container's store services come up without a host nix-daemon
  unit and without bind-mounts of the host store database/socket that would
  break the container's custom daemon

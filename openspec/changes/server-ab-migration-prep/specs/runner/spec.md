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

### Requirement: A/B signing key is consumed through credentials

When `runner.deploy.ab.signingKeyFile` is configured, both the in-container
runner services and the host `nixtache-ab-gc.service` SHALL receive the key as
`sysupdate_signing_key` through systemd `LoadCredential`. Their scripts SHALL
read it from `$CREDENTIALS_DIRECTORY`, not from the original host path.

#### Scenario: Host retain-GC signs through its credential

- **WHEN** the host retain-GC regenerates a staging manifest with a signing key
  configured
- **THEN** the unit has `LoadCredential = sysupdate_signing_key:<signingKeyFile>`
  and GPG imports `$CREDENTIALS_DIRECTORY/sysupdate_signing_key`, producing a
  verifiable signature without reading the original path in the script

#### Scenario: Deploy action uses the same credential contract

- **WHEN** a deploy job signs a staging manifest
- **THEN** its runner service exposes the same credential name and the action
  imports it from its job credentials directory

#### Scenario: No signing key leaves no credential

- **WHEN** `signingKeyFile = null`
- **THEN** neither service receives the signing credential and retain-GC removes
  stale detached signatures rather than presenting them as current

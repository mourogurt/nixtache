# Spec Delta

## MODIFIED Requirements

### Requirement: Runner container operates on a nix-less appliance host

When the host has nix disabled (`nix.enable = false`, e.g. an A/B appliance), the runner container MUST run with its own nix module disabled, the module MUST render the container's `nix.conf` itself while preserving the configured system-features, substituters and trusted-users, and the nix CLI MUST be shipped explicitly. Operation over the appliance's input-addressed lower closure MUST NOT require `ca-derivations`.

#### Scenario: Container starts and serves CI on an appliance host

- **WHEN** the runner module is enabled on a host with `nix.enable = false` and an input-addressed appliance lower store
- **THEN** the container starts, evaluates with its internal nix module disabled, and exposes a working nix CLI governed by the module-rendered `nix.conf` without requiring CA derivation support

#### Scenario: Runner store operations accept snapshot-derived lower records

- **WHEN** a runner seeds a clone store or opens an overlay lower from an appliance's snapshot-derived database with CA derivation support disabled
- **THEN** all shipped lower paths retain their validity and references, closure copying completes without NAR hash mismatches, and subsequent CI store operations succeed

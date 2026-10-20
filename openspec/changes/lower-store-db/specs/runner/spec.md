# Spec Delta

## ADDED Requirements

### Requirement: Runner container operates on a nix-less appliance host

When the host has nix disabled (`nix.enable = false`, e.g. an A/B appliance), the runner container MUST run with its own nix module disabled, the module MUST render the container's `nix.conf` itself (preserving the configured system-features, substituters and trusted-users, and enabling the `ca-derivations` experimental feature), and the nix CLI MUST be shipped in the container explicitly, so CI jobs keep their nix surface without a host nix installation.

#### Scenario: Container starts and serves CI on an appliance host

- **WHEN** the runner module is enabled on a host with `nix.enable = false`
- **THEN** the container starts, evaluates with its internal nix module disabled, and exposes a working nix CLI governed by the module-rendered `nix.conf` (including `ca-derivations`)

### Requirement: Clone mode seeds from the real host store database

In clone mode on an appliance host, the storage seeder MUST enumerate the host store through a writable scratch copy of the host's store database, so the relocated store receives every path registered in the shipped lower database.

#### Scenario: Clone receives the host store closure on an appliance

- **WHEN** the runner container's storage seeder runs on an appliance host in clone mode
- **THEN** the seed copies every path registered in the host store's database into the relocated store, and post-seed CI builds resolve host-store paths locally

### Requirement: Overlay mode uses a local lower store on appliance hosts

In overlay mode on a nix-less host, the custom daemon's overlay store URL MUST use the local lower store (`lower-store=local`), not the daemon lower: the read-only bind-mounted host database is real and readable, while a daemon lower would self-reference (no system daemon exists on the host) and fork-loop.

#### Scenario: Overlay daemon serves a coherent merged view on an appliance

- **WHEN** the runner container runs in overlay mode on an appliance host
- **THEN** the overlay store opens the host database as a local lower, lower paths resolve with their validity records, builds write to the upper layer, and no daemon self-connection loop occurs

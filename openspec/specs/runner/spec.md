# runner Specification

## Purpose

Runs Forgejo Actions CI jobs in a dedicated NixOS container with explicitly
controlled resource usage, so builds coexist with other services on a shared
host and consumers can size and diagnose the container themselves.

## Requirements

### Requirement: Container memory budget

The module SHALL expose `services.nixtache.runner.memoryMax` and
`memoryHigh` options, applied as the hard (`MemoryMax`) and throttling
(`MemoryHigh`) memory limits of the `container@<name>` systemd unit. The
defaults SHALL be `"16G"` and `"14G"` — a budget sized for a host shared with
other services.

#### Scenario: Default budget fits a shared host

- **WHEN** the runner module is enabled and `memoryMax`/`memoryHigh` are not set
- **THEN** the container unit evaluates with `MemoryMax=16G` and `MemoryHigh=14G`

#### Scenario: Consumer overrides the budget

- **WHEN** the consumer sets `memoryMax = "32G"` and `memoryHigh = "30G"`
- **THEN** the container unit carries exactly `MemoryMax=32G` and `MemoryHigh=30G`

### Requirement: Container swap ceiling

The module SHALL expose `services.nixtache.runner.memorySwapMax`, applied as
`MemorySwapMax` on the container unit. It SHALL default to unset, imposing no
module-level swap ceiling, so host swap (e.g. zram) remains fully available to
absorb build memory peaks.

#### Scenario: No ceiling by default

- **WHEN** `memorySwapMax` is not set
- **THEN** the container unit carries no `MemorySwapMax` directive

#### Scenario: Consumer sets a ceiling

- **WHEN** the consumer sets `memorySwapMax = "8G"`
- **THEN** the container unit carries `MemorySwapMax=8G`

### Requirement: Container CPU fairness weight

The module SHALL expose `services.nixtache.runner.cpuWeight` (integer
1..10000), applied as `CPUWeight` on the container unit to set its CPU share
relative to co-hosted services under contention. It SHALL default to unset,
keeping the systemd default weight.

#### Scenario: No weight by default

- **WHEN** `cpuWeight` is not set
- **THEN** the container unit carries no `CPUWeight` directive

#### Scenario: Consumer sets a weight

- **WHEN** the consumer sets `cpuWeight = 200`
- **THEN** the container unit carries `CPUWeight=200`

### Requirement: Container IO fairness weight

The module SHALL expose `services.nixtache.runner.ioWeight` (integer
1..10000), applied as `IOWeight` on the container unit to set its IO share
relative to co-hosted services under contention. It SHALL default to unset,
keeping the systemd default weight.

#### Scenario: No weight by default

- **WHEN** `ioWeight` is not set
- **THEN** the container unit carries no `IOWeight` directive

#### Scenario: Consumer sets a weight

- **WHEN** the consumer sets `ioWeight = 50`
- **THEN** the container unit carries `IOWeight=50`

### Requirement: Resource sizing and kill-diagnostics documentation

The documentation SHALL explain memory/swap sizing, the
`nixSettings.cores`-vs-headroom trade-off, and signal-9 diagnostics using
`machine.slice` cgroup counters, kernel logs, host/container systemd-oomd
and CI cancellation evidence.

#### Scenario: Consumer sizes the container

- **WHEN** a consumer needs to fit the runner container into a host RAM budget
- **THEN** the documentation explains memory/swap sizing and the
  cores-vs-memory trade-off, without requiring source-code reading

#### Scenario: Consumer diagnoses a killed build

- **WHEN** a CI build dies with "builder failed due to signal 9"
- **THEN** the documentation provides a diagnostic decision tree covering
  cgroup OOM counters, kernel logs, both systemd-oomd layers, and CI-side job
  cancellation

### Requirement: Runner registration via uuid and token pair

The module SHALL wire each enabled `services.nixtache.runner.instances.<name>`
to an instance of the in-container `services.forgejo-runner` module whose
connection `default` carries `url = services.nixtache.runner.forgejoUrl`,
`uuid = instances.<name>.uuid`, and the runner token read from a read-only
bind mount of `instances.<name>.tokenFile` via the module's
`secrets.server.connections.default.token_url` mechanism. Each instance
SHALL be its own registration (own uuid and own token).

#### Scenario: Token file holds the bare token

- **WHEN** a consumer prepares an instance's token file
- **THEN** it contains the bare runner token — no `TOKEN=` prefix and no
  environment-file syntax; the uuid + token pair is obtained from Forgejo
  when the registration is created

#### Scenario: Default instance is fully wired

- **WHEN** one enabled instance `default` is configured with `uuid` and
  `tokenFile`
- **THEN** the container config contains
  `services.forgejo-runner.instances.default` with
  `settings.server.connections.default.url = forgejoUrl` and
  `settings.server.connections.default.uuid` equal to the configured uuid,
  and `secrets.server.connections.default.token_url` pointing at the
  bind-mounted token path `/var/secrets/runner/default/token`
- **AND** that bind mount's hostPath is the configured `tokenFile`, read-only

#### Scenario: Two instances are independent registrations

- **WHEN** instances `default` and `test` are both enabled
- **THEN** each gets its own uuid in its own connection map and its own
  read-only token bind mount `runner-token-<name>`

### Requirement: Instance options track the forgejo-runner module

`instances.<name>.labels` SHALL land in `settings.runner.labels` of the
corresponding in-container instance, keeping the default
`[ "nixos:host" ]`. The module SHALL NOT expose a runner-name option: the
name is fixed in Forgejo when the registration is created, so
`instances.<name>.name` SHALL fail evaluation as an unknown option.

#### Scenario: Labels reach the instance settings

- **WHEN** an instance sets `labels = [ "test:host" ]`
- **THEN** the in-container instance's `settings.runner.labels` is
  `[ "test:host" ]`

#### Scenario: Runner name is not settable

- **WHEN** a consumer sets `instances.default.name`
- **THEN** evaluation fails with an unknown-option error

### Requirement: Container nix daemon trusts the runner service users

The in-container `nix.settings.trusted-users` SHALL include
`forgejo-runner-<name>` — the NSS-visible name of the dynamic user of each
`forgejo-runner-<name>.service` — for every enabled instance. Host-mode jobs
therefore stay trusted nix clients: they may use the configured substituters
and copy closures out of the store (direct deploy).

#### Scenario: Trusted users track the instances

- **WHEN** instances `default` and `test` are enabled
- **THEN** the container's `nix.settings.trusted-users` contains
  `forgejo-runner-default` and `forgejo-runner-test` for those registrations

#### Scenario: Trusted users stay correct with no instances beyond default

- **WHEN** only the `default` instance is enabled
- **THEN** `trusted-users` contains `forgejo-runner-default` exactly for
  that instance and nothing else beyond the module's static entries

### Requirement: Registration migration documentation

The user guide SHALL document the one-time migration from the
self-registration model to the uuid + token model: extracting `uuid` and
`token` from the `.runner` file of a previously registered runner
(`/var/lib/gitea-runner/<name>/.runner` inside the still-running old
container), the token-file format change, and creating a fresh runner
registration in Forgejo.

#### Scenario: Consumer migrates an existing runner

- **WHEN** a consumer with a running old-model runner upgrades nixtache
- **THEN** the user guide explains how to read the old `.runner` file and
  where to put each value, without requiring source-code reading

#### Scenario: Consumer registers a new runner

- **WHEN** a consumer has no old registration to reuse
- **THEN** the user guide explains how to create a runner registration in
  Forgejo and obtain the uuid + token pair

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

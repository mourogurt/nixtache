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

The technical-details documentation layer SHALL cover runner container
resource control: sizing the memory budget for a shared host, host swap as
the buffer that lets large builds survive a tight RAM budget, the relation
between build parallelism (`nixSettings.cores`) and memory headroom, and a
decision tree for diagnosing a CI build killed by signal 9 (cgroup event
counters under `machine.slice`, kernel log search, the host and container
systemd-oomd layers, and CI-side job cancellation surfacing as signal 9).

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
- **THEN** it contains the bare runner token — no `TOKEN=` prefix, no
  environment-file syntax: runners no longer self-register, the uuid +
  token pair is obtained from Forgejo when the registration is created

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
`[ "nixos:host" ]`. The module SHALL NOT re-expose a runner-name option:
runners no longer self-report their name to Forgejo (the name is fixed when
the registration is created), so `instances.<name>.name` SHALL fail
evaluation.

#### Scenario: Labels reach the new settings location

- **WHEN** an instance sets `labels = [ "nixos:test" ]`
- **THEN** the in-container instance's `settings.runner.labels` is
  `[ "nixos:test" ]`

#### Scenario: Runner name is not settable

- **WHEN** a consumer sets `instances.default.name`
- **THEN** evaluation fails (the option no longer exists)

### Requirement: Container nix daemon trusts the runner service users

The in-container `nix.settings.trusted-users` SHALL include
`forgejo-runner-<name>` — the NSS-visible name of the dynamic user of each
`forgejo-runner-<name>.service` — for every enabled instance, and SHALL NOT
reference the removed `gitea-runner` account. Host-mode jobs therefore stay
trusted nix clients: they may use the configured substituters and copy
closures out of the store (direct deploy).

#### Scenario: Trusted users track the instances

- **WHEN** instances `default` and `test` are enabled
- **THEN** the container's `nix.settings.trusted-users` contains
  `forgejo-runner-default` and `forgejo-runner-test`, and does not contain
  `gitea-runner`

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

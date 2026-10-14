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

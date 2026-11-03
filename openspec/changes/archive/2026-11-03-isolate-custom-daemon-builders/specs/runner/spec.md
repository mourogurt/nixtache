# Spec Delta

## ADDED Requirements

### Requirement: Custom daemon uses isolated builder identities

For every relocated store, `nix-daemon-custom` SHALL use a dedicated static builder group and accounts whose numeric UIDs/GID are disjoint from the host Nix builder IDs. Custom-daemon builds MUST NOT run as root or use automatic UID allocation, and the container's system daemon SHALL retain its independent builder configuration.

#### Scenario: Nix-enabled host runs two daemon configurations

- **WHEN** the runner uses a relocated store on a Nix-enabled host
- **THEN** the custom daemon builds through its dedicated group and UIDs while the container system daemon keeps its existing `nixbld` configuration

#### Scenario: Appliance custom daemon builds without root

- **WHEN** the runner uses a relocated store in either clone or overlay mode on a Nix-less appliance host
- **THEN** the custom daemon has dedicated build users and completes builds as those non-root users

#### Scenario: Automatic UID allocation cannot bypass isolation

- **WHEN** automatic UID allocation is enabled elsewhere in the container Nix configuration
- **THEN** the custom daemon still allocates builds only from its dedicated static builder accounts

### Requirement: Independent daemon cleanup cannot kill another build

Host and runner-container Nix daemons SHALL use disjoint numeric builder UIDs so UID-based cleanup by one daemon cannot terminate processes belonging to a concurrent build owned by the other daemon.

#### Scenario: Host build cleanup preserves the container build

- **WHEN** host and custom-daemon builds are running concurrently and the host build finishes or is cancelled
- **THEN** host cleanup does not signal the container builder, which remains alive and can complete its output

#### Scenario: Container build cleanup preserves the host build

- **WHEN** host and custom-daemon builds are running concurrently and the container build finishes or is cancelled
- **THEN** custom-daemon cleanup does not signal the host builder, which remains alive and can complete its output

### Requirement: Declarative host ID collisions are rejected

The module SHALL reject a relocated-store configuration when a dedicated custom-builder UID or GID overlaps a statically declared host user or group ID, rather than allowing unsafe concurrent daemon operation.

#### Scenario: Host account occupies the dedicated range

- **WHEN** a statically declared host user or group occupies an ID selected for the custom builder accounts or group
- **THEN** evaluation fails with an error identifying the ID collision before either daemon can run with overlapping builder identities

## MODIFIED Requirements

### Requirement: Resource sizing and kill-diagnostics documentation

The documentation SHALL explain memory/swap sizing, the
`nixSettings.cores`-vs-headroom trade-off, and signal-9 diagnostics using
`machine.slice` cgroup counters, kernel logs, host/container systemd-oomd,
CI cancellation evidence, and cross-daemon UID-cleanup evidence.

#### Scenario: Consumer sizes the container

- **WHEN** a consumer needs to fit the runner container into a host RAM budget
- **THEN** the documentation explains memory/swap sizing and the
  cores-vs-memory trade-off, without requiring source-code reading

#### Scenario: Consumer diagnoses a killed build

- **WHEN** a CI build dies with "builder failed due to signal 9"
- **THEN** the documentation provides a diagnostic decision tree covering
  cgroup OOM counters, kernel logs, both systemd-oomd layers, CI-side job
  cancellation, and UID-wide cleanup by an independent Nix daemon

#### Scenario: Consumer correlates concurrent daemon builds

- **WHEN** a killed CI build coincided with a host Nix build
- **THEN** the documentation explains how to compare numeric builder UIDs and daemon cleanup evidence on both sides

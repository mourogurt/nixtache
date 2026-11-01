# Spec Delta

## ADDED Requirements

### Requirement: Nixtache has a self-update entry point

Nixtache SHALL provide scheduled and manually dispatched self-update entry
points that run the reusable `update-flake.yml` pipeline against nixtache's own
checkout.

#### Scenario: Scheduled self-update targets nixtache

- **WHEN** the nixtache self-update schedule fires
- **THEN** the shared update-flake pipeline runs with nixtache as the caller
  and updates nixtache's own `flake.lock`

#### Scenario: Manual self-update retains shared pipeline behavior

- **WHEN** a maintainer manually dispatches the nixtache self-update workflow
- **THEN** the run uses the same update-flake pipeline and its credential,
  signing, validation-log and artifact behavior as consumer updates

### Requirement: Update validation matches the caller profile

`update-flake.yml` SHALL support consumer and nixtache-self validation
profiles, defaulting to the consumer profile for existing callers.

#### Scenario: Existing consumer caller retains full validation

- **WHEN** a consumer calls `update-flake.yml` without selecting a validation
  profile
- **THEN** the run performs flake validation followed by the existing NixOS
  configuration and devShell rebuilds

#### Scenario: Nixtache self-update skips consumer-only rebuilds

- **WHEN** the nixtache self-update caller selects the nixtache-self profile
- **THEN** the run performs flake validation and skips the consumer-oriented
  NixOS configuration and devShell rebuilds before pushing validated changes

### Requirement: Nixtache self-update selects an available runner

The self-update caller SHALL select an online `kvm` candidate when its
runner-discovery preflight finds one and SHALL fall back to `test` otherwise.
A capability probe on that candidate SHALL also select `test` when `/dev/kvm`
is not usable.

#### Scenario: No online KVM runner is registered

- **WHEN** the self-update preflight finds no online runner with the `kvm`
  label, including when runner discovery is unavailable
- **THEN** the shared update pipeline runs on the `test` runner

#### Scenario: The discovered KVM candidate has no usable device

- **WHEN** an online runner with the `kvm` label has no usable `/dev/kvm`
- **THEN** the capability probe selects `test` for the shared update pipeline

### Requirement: Nixtache self-update gates pushes on available VM tests

When the selected runner has a usable `/dev/kvm`, the nixtache-self validation
profile SHALL build the full `vmTests.x86_64-linux` inventory against the
updated checkout after flake validation and before pushing the lock-file
commit. Otherwise, it SHALL record a skip without VM discovery or builds and
allow the update pipeline to continue.

#### Scenario: KVM is unavailable on the selected runner

- **WHEN** the selected self-update runner has no usable `/dev/kvm`
- **THEN** the run records why VM validation was skipped and does not discover
  or build VM suites
- **AND** the remaining update pipeline, including its push, may continue

#### Scenario: Updated lock passes the full VM inventory

- **WHEN** nixtache self-update produces a changed `flake.lock` and the
  selected runner has a usable `/dev/kvm`
- **THEN** flake validation and every VM suite complete successfully against
  that updated checkout before the signed commit is pushed

#### Scenario: A VM failure blocks publication

- **WHEN** any VM suite fails during a nixtache self-update run
- **THEN** the run fails and does not push the updated lock-file commit
- **AND** the VM failure output is retained in the run artifacts

#### Scenario: Consumer updates do not inherit nixtache VM validation

- **WHEN** a consumer uses the default consumer validation profile
- **THEN** the update pipeline retains its existing flake, configuration and
  devShell validation without running nixtache's `vmTests` inventory

### Requirement: LFS-enabled workflows select a supported transport

Reusable workflows that fetch Git LFS content SHALL select a transport supported
by the current Forgejo instance instead of unconditionally fetching through the
checkout's HTTPS endpoint. They SHALL prefer pure-SSH LFS when it is usable,
SHALL retain HTTPS LFS as a fallback and SHALL NOT override an explicit
repository LFS endpoint configuration.

#### Scenario: Pure-SSH LFS is available

- **WHEN** a runner has SSH credentials and the Forgejo instance supports
  pure-SSH LFS for the caller repository
- **THEN** LFS objects are fetched over SSH after SSH setup and before
  build/update work
- **AND** an update push continues to use SSH for LFS transfer

#### Scenario: HTTPS LFS fallback is required

- **WHEN** pure-SSH LFS is unavailable but the HTTPS LFS endpoint is usable
- **THEN** the workflow fetches LFS objects over HTTPS without requiring a
  consumer wrapper change

#### Scenario: Repository LFS configuration is explicit

- **WHEN** the caller repository explicitly configures its LFS endpoint
- **THEN** automatic transport selection preserves that configuration

#### Scenario: No LFS transport is usable

- **WHEN** neither pure-SSH nor HTTPS LFS can transfer objects for the caller
  repository
- **THEN** the workflow fails before build/update work with a diagnostic that
  identifies the unsuccessful transports without exposing credentials

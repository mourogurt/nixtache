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

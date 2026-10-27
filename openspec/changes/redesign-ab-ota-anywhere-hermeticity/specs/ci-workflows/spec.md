# ci-workflows Specification — delta (redesign-ab-ota-anywhere-hermeticity)

## ADDED Requirements

### Requirement: VM suite matrix parking is tracked and temporary

The `vmtests` workflow's suite matrix MUST contain every `vmTests`
suite except those explicitly parked: a parked (excluded) suite MUST be
marked at the exclusion site with a comment naming the open change that
tracks its rework, and MUST be re-added to the matrix once that change
completes. Every non-parked suite in the matrix MUST pass a full
dispatch.

#### Scenario: Parked suite references its tracking change

- **WHEN** a suite is excluded from the `vmtests.yml` matrix
- **THEN** the exclusion site carries a comment naming the open change
  tracking the rework, and the suite remains buildable via
  `nix build .#vmTests.…` locally

#### Scenario: Non-parked suite fails a full dispatch

- **WHEN** a suite in the matrix fails and no parking comment covers it
- **THEN** the dispatch is red and the failure is treated as a regression
  to fix, not as a known-parked state

# ci-workflows Specification

## Purpose

Defines the behavioral contract of nixtache's reusable CI workflows and their
composite actions: sandbox detection before builds and failure-log capture, so
every consumer run is diagnosable and builds behave identically across
`nix-check.yml` and `update-flake.yml`.

## Requirements

### Requirement: Sandbox probe before builds in every building workflow

Every reusable workflow that invokes a build action (`flake-validation`,
`rebuild-configurations`, `rebuild-devshells`) SHALL run the `sandbox-probe`
composite action before the first nix build invocation, so `SANDBOX_OK`
reflects the actual runner instead of defaulting to unset/`--no-sandbox`.

#### Scenario: update-flake probes the sandbox like nix-check

- **WHEN** `update-flake.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before `flake-validation` and
  exports `SANDBOX_OK=1`, and subsequent build steps run without
  `--no-sandbox`

#### Scenario: probe failure self-heals to --no-sandbox

- **WHEN** `update-flake.yml` runs on a runner whose sandbox is broken
- **THEN** `sandbox-probe` exports `SANDBOX_OK=0` and all build steps append
  `--no-sandbox` instead of failing

### Requirement: Sandbox probe respects the update-flake guard

In `update-flake.yml`, the `sandbox-probe` step SHALL carry the same
`steps.guard.outputs.enabled == 'true'` condition as the other work steps, so
a runner without `updateSshCreds` still no-ops the whole job cleanly.

#### Scenario: disabled update-flake skips the probe

- **WHEN** `update-flake.yml` runs and `NIXTACHE_UPDATE_GIT_USER` is absent
- **THEN** the guard outputs `enabled=false` and the `sandbox-probe` step is
  skipped along with every other work step

### Requirement: Validation failure logs are captured as artifacts

The `flake-validation` composite action SHALL write the full
`nix flake check` output to `artifacts/flake-check.log` while keeping it on
the console (tee semantics), so a failed validation leaves a downloadable
log in the `logs` artifact.

#### Scenario: flake check failure leaves a log file

- **WHEN** `nix flake check` fails inside `flake-validation`
- **THEN** `artifacts/flake-check.log` contains the full check output and the
  step still exits non-zero

#### Scenario: console output is preserved

- **WHEN** `flake-validation` runs, passing or failing
- **THEN** the `nix flake check` output appears in the job log exactly as
  before, in addition to the artifact file

### Requirement: Flake-update failure logs are captured as artifacts

The "Update Flakes Inputs" step of `update-flake.yml` SHALL write the full
`nix flake update --commit-lock-file` output to `artifacts/flake-update.log`
while keeping it on the console.

#### Scenario: update failure leaves a log file

- **WHEN** `nix flake update --commit-lock-file` fails
- **THEN** `artifacts/flake-update.log` contains the full command output and
  the step exits non-zero

### Requirement: The artifacts directory always exists before upload

Every reusable workflow with an always-run `upload-artifact` step over
`artifacts/` SHALL ensure the directory exists before any step that may fail,
so the upload never reports "no files found" for a run that reached the
pipeline stages.

#### Scenario: early failure still uploads a log

- **WHEN** the first pipeline step of `update-flake.yml` (flake update) fails
- **THEN** the `upload-artifact` step finds `artifacts/` populated with at
  least the failed step's log

### Requirement: update-flake guard validates the push credential

The `update-flake.yml` guard SHALL verify the configured update SSH credential
actually authenticates and can read the caller repository over the push URL
(via `git ls-remote`), instead of only testing that `NIXTACHE_UPDATE_GIT_USER`
is non-empty. A runner without `updateSshCreds` keeps the no-op semantics.

#### Scenario: unconfigured runner still no-ops

- **WHEN** `update-flake.yml` runs and `NIXTACHE_UPDATE_GIT_USER` is absent
  (`updateSshCreds = null`)
- **THEN** the guard outputs `enabled=false` with a warning and every work
  step is skipped, exactly as before

#### Scenario: configured but invalid credential fails fast

- **WHEN** `updateSshCreds` is set but the key cannot authenticate or read the
  caller repository over the push URL
- **THEN** the guard fails the job immediately with an error naming the failed
  probe, instead of discovering the failure at the final `git push`

#### Scenario: valid credential enables the pipeline

- **WHEN** `updateSshCreds` is set and the probe succeeds
- **THEN** the guard outputs `enabled=true` and the pipeline proceeds

### Requirement: update-flake sets up fetch credentials for private inputs

`update-flake.yml` SHALL configure the `flake` SSH credential bundle (the same
one `nix-check.yml` uses) in addition to `update`, so `nix flake update` can
fetch private flake inputs of the caller repository.

#### Scenario: private input fetches successfully

- **WHEN** the caller flake has a private `git+ssh` input and the runner
  provides `flakeSshCreds`
- **THEN** `nix flake update` fetches the input without
  `Permission denied (publickey)` errors

#### Scenario: missing flake credentials degrade gracefully for public inputs

- **WHEN** the caller flake has only public inputs and the runner does not
  provide `flakeSshCreds`
- **THEN** the setup step warns and skips the flake bundle and the update
  proceeds

### Requirement: Swallowed fetch errors fail the update step

The "Update Flakes Inputs" step SHALL fail when the captured
`artifacts/flake-update.log` contains nix fetch errors (`error: Failed to
fetch`, `Permission denied` during fetch), even when
`nix flake update --commit-lock-file` itself exits 0 through the
expired-cache fallback.

#### Scenario: cache fallback no longer hides a failed update

- **WHEN** nix cannot fetch an input and falls back to an expired cached ref,
  exiting 0
- **THEN** the step exits non-zero and the log artifact contains the fetch
  error

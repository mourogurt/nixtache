# Spec Delta

## ADDED Requirements

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

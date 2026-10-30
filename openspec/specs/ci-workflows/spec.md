# ci-workflows Specification

## Purpose

Defines the behavioral contract of the CI workflows nixtache ships — the
reusable workflows called from consumer repositories and nixtache's own
self-CI — and their composite actions: sandbox detection before builds and
failure-log capture, so every consumer and self-CI run is diagnosable and
builds behave identically across `nix-check.yml` and `update-flake.yml`.

## Requirements

### Requirement: Sandbox probe before builds in every building workflow

Every workflow nixtache ships — reusable or its own CI — that invokes a
build action (`flake-validation`, `rebuild-configurations`,
`rebuild-devshells`, `generate-docs`, `deploy-target`) or runs
`nix build` / `nix flake check` directly SHALL run the `sandbox-probe`
composite action before the first such step, so `SANDBOX_OK` reflects the
actual runner instead of defaulting to unset/`--no-sandbox`.

#### Scenario: update-flake probes the sandbox like nix-check

- **WHEN** `update-flake.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before `flake-validation` and
  exports `SANDBOX_OK=1`, and subsequent build steps run without
  `--no-sandbox`

#### Scenario: probe failure self-heals to --no-sandbox

- **WHEN** `update-flake.yml` runs on a runner whose sandbox is broken
- **THEN** `sandbox-probe` exports `SANDBOX_OK=0` and all build steps append
  `--no-sandbox` instead of failing

#### Scenario: ci.yml probes before its first build step

- **WHEN** `ci.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before the `flake-validation`
  step (whose `nix flake check` builds `checks.*`), so the check — and every
  later build step — runs sandboxed rather than defaulting to
  `--no-sandbox`

#### Scenario: vmtests suite self-heals on a broken-sandbox KVM runner

- **WHEN** `vmtests.yml` runs a suite on a KVM-capable runner whose nix
  sandbox is broken
- **THEN** `sandbox-probe` exports `SANDBOX_OK=0` and the suite's
  `nix build` invocation appends `--no-sandbox` instead of failing on
  missing namespaces

#### Scenario: docs workflow probes before generate-docs

- **WHEN** `docs.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before the `generate-docs`
  step, so the docs build runs sandboxed instead of always appending
  `--no-sandbox` from an unset `SANDBOX_OK`

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
  step is skipped without running the update pipeline

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

#### Scenario: cache fallback does not hide a failed update

- **WHEN** nix cannot fetch an input and falls back to an expired cached ref,
  exiting 0
- **THEN** the step exits non-zero and the log artifact contains the fetch
  error

### Requirement: SSH config covers every host the job contacts

Reusable workflows SHALL pass `ssh-setup` the complete set of hostnames the
job contacts over SSH — the push host (`NIXTACHE_GIT_SSH_HOST`) plus every
SSH host referenced by the caller's `flake.lock` input URLs — so the
credential keys are offered on every connection nix makes.

#### Scenario: private input on an alias host fetches

- **WHEN** the push host is `zinzaguras.ru` but `flake.lock` input URLs use
  `ssh://forgejo@code.zinzaguras.ru/…`
- **THEN** the generated SSH config has `Host` blocks for both hostnames, and
  `nix flake update` offers the credential key when connecting to
  `code.zinzaguras.ru`

#### Scenario: host list is derived from flake.lock, not hardcoded

- **WHEN** `update-flake.yml` or `nix-check.yml` runs
- **THEN** the host list passed to `ssh-setup` is the push host (from
  `NIXTACHE_GIT_SSH_HOST`) plus the SSH hosts extracted from the checked-out
  `flake.lock`, deduplicated — no consumer hostname is hardcoded in the
  workflow files

#### Scenario: guard still probes the push host

- **WHEN** `update-flake.yml` validates the update credential
- **THEN** the `ls-remote` probe targets the push URL on
  `NIXTACHE_GIT_SSH_HOST`, regardless of how many hosts the SSH config covers

### Requirement: ssh-setup git-host accepts a host list

`ssh-setup`'s `git-host` input SHALL accept a space-separated host list,
writing one `Host` block per host; a `host:port` token maps to `HostName` +
`Port` in that host's own block.

#### Scenario: single-host caller gets one complete Host block

- **WHEN** `ssh-setup` is invoked with one host and one credential bundle
- **THEN** the generated SSH config contains that host in both `Host` and
  `HostName`, the selected transport user in `User`, the bundle's `id_key` in
  `IdentityFile`, and a `Port` line only when the input used `host:port`

#### Scenario: per-host port stays per-host

- **WHEN** the host list is `alpha.example beta.example:2222`
- **THEN** the generated config has a `Port 2222` line only inside
  `beta.example`'s block

### Requirement: vmtests suite jobs are diagnosable from concise output and a full-log artifact

Each `vmtests.yml` matrix job SHALL keep its step output limited to what
the suite itself reported, while the complete `nix build -L` transcript of
that suite is captured as a file and attached by the log upload step on
every outcome. The upload step SHALL NOT be a silent no-op: if a suite ran,
its full log exists as an artifact.

#### Scenario: passing suite

- **WHEN** a vmtests suite builds and its test script reports all checks ok
- **THEN** the job's step output contains the suite's own ok/verdict lines
  and not the raw build log, and the uploaded artifact for that suite holds
  the full `nix build -L` transcript

#### Scenario: build failure before the test

- **WHEN** a suite's build fails before any test executes
- **THEN** the job's step output states that the build never reached the
  test and shows the closing build error, and the uploaded artifact still
  holds the full transcript

### Requirement: vmtests matrix jobs are named after their suites

Each `vmtests.yml` matrix job SHALL be displayed under its bare suite name,
not prefixed with the job id.

#### Scenario: jobs are named after their suites

- **WHEN** the vmtests matrix runs
- **THEN** each job is displayed under its bare suite name (for example
  `ab-vm`), not prefixed with the job id (not `suites (ab-vm)`)

### Requirement: full-matrix vmtests dispatches bound suite concurrency

A full-matrix `vmtests` dispatch SHALL bound how many suites execute
concurrently, so a single dispatch cannot exhaust the memory or KVM capacity
of one runner host and turn unrelated suites into host-level kills
(QEMU/build processes dying with connection resets or SIGKILL).

#### Scenario: full dispatch on one KVM runner

- **WHEN** a full-matrix vmtests dispatch runs on a single `kvm`-label
  runner
- **THEN** no more than the configured number of suites execute at once,
  and the dispatch finishes without host-level kills attributable to runner
  overload

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

# Spec Delta

## MODIFIED Requirements

### Requirement: Sandbox probe before builds in every building workflow

Every workflow nixtache ships — reusable or its own CI — that invokes a
build action (`flake-validation`, `rebuild-configurations`,
`rebuild-devshells`, `generate-docs`, `deploy-target`) or runs
`nix build` / `nix flake check` directly SHALL run the `sandbox-probe`
composite action before the first such step. Each probe SHALL require a fresh
builder execution so `SANDBOX_OK` reflects the current runner instead of a
cached result or an unset fallback.

#### Scenario: update-flake probes the sandbox like nix-check

- **WHEN** `update-flake.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before `flake-validation` and
  exports `SANDBOX_OK=1`, and subsequent build steps run without
  `--no-sandbox`

#### Scenario: Existing output cannot satisfy a later probe

- **WHEN** another job runs on the same runner and commit after an earlier
  probe already realized its output
- **THEN** the later probe uses a per-run unique output and executes its
  builder again rather than returning success from an existing or substituted
  store path

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

- **WHEN** `vmtests.yml` runs a suite on a KVM-capable runner whose Nix
  sandbox is broken
- **THEN** `sandbox-probe` exports `SANDBOX_OK=0` and the suite's
  `nix build` invocation appends `--no-sandbox` instead of failing on
  missing namespaces

#### Scenario: docs workflow probes before generate-docs

- **WHEN** `docs.yml` runs on a runner with a working sandbox
- **THEN** the `sandbox-probe` step executes before the `generate-docs`
  step, so the docs build runs sandboxed instead of always appending
  `--no-sandbox` from an unset `SANDBOX_OK`

### Requirement: The artifacts directory always exists before upload

Every reusable workflow with an always-run `upload-artifact` step over
`artifacts/` SHALL ensure the directory exists before any step that may fail,
so the upload never reports "no files found" for a run that reached the
pipeline stages.

#### Scenario: early failure still uploads a log

- **WHEN** the first pipeline step of `update-flake.yml` (flake update) fails
- **THEN** the `upload-artifact` step finds `artifacts/` populated with at
  least the failed step's log

#### Scenario: Setup failure also finds the artifact directory

- **WHEN** host derivation, SSH setup or the sandbox probe fails in
  `nix-check.yml` or `update-flake.yml` before the first build
- **THEN** `artifacts/` already exists for the always-run upload, and any log
  produced by the failed step can be included

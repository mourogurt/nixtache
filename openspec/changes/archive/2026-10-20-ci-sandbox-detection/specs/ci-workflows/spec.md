# Spec Delta

## MODIFIED Requirements

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

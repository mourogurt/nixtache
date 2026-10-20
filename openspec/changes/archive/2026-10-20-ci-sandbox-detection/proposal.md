# Proposal

## Why

nixtache's own CI workflows violate the sandbox-probe contract that the
reusable workflows (`nix-check.yml`, `update-flake.yml`, `deploy.yml`) already
follow. In `ci.yml` the probe runs *after* `flake-validation`, so
`nix flake check` (which builds `checks.*`) always sees `SANDBOX_OK` unset and
silently falls back to `--no-sandbox` — even on runners with a working sandbox,
the heaviest build step of nixtache's own CI never builds sandboxed.
`vmtests.yml` has no probe at all: its `nix build` carries no
`SANDBOX_FLAG`, so a KVM runner with a broken sandbox fails the suite outright
instead of self-healing. The same gap exists in the reusable `docs.yml`, which
invokes the SANDBOX_OK-consuming `generate-docs` action without a preceding
probe.

## What Changes

- `ci.yml`: move the `sandbox-probe` step before the first build step
  (`flake-validation`), matching the `nix-check.yml` step order, so every
  subsequent step (`nix flake check`, module-test rebuilds, option-docs
  generation) sees the real `SANDBOX_OK` value.
- `vmtests.yml`: add a `sandbox-probe` step after checkout and apply the
  `SANDBOX_OK`-derived flag to the suite `nix build` invocation, giving VM
  suites the same broken-sandbox self-heal (`--no-sandbox`) as the pure-eval
  suites.
- `docs.yml`: add a `sandbox-probe` step before `generate-docs` so docs builds
  run sandboxed on healthy runners instead of always `--no-sandbox`.
- Extend the pure-eval drift-check pattern (`tests/ab-deploy-drift.nix`) with
  a suite asserting, from the real workflow YAML, that every
  nixtache-shipped workflow probes the sandbox before its first
  SANDBOX_OK-consuming step.
- Update `doc/technical_details/sandboxing.md` and
  `doc/technical_details/workflow-mechanics.md` to state the widened contract.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ci-workflows`: the "Sandbox probe before builds in every building workflow"
  requirement currently scopes the probe contract to reusable workflows and
  lists only `flake-validation`, `rebuild-configurations`,
  `rebuild-devshells` as build actions. It is widened to (a) the full set of
  `SANDBOX_OK`-consuming actions (`generate-docs`, `deploy-target` included),
  (b) nixtache's own CI workflows (`ci.yml`, `vmtests.yml`), and (c) the
  reusable `docs.yml` — every workflow nixtache ships that builds SHALL probe
  first. The capability's purpose statement grows from "reusable CI
  workflows" to "CI workflows shipped by nixtache, reusable or self-CI".

## Impact

- Workflows: `.forgejo/workflows/ci.yml`, `vmtests.yml`, `docs.yml` (step
  moves/additions only; no triggers, jobs or action inputs change).
- Tests: new pure-eval suite in `tests/` wired into `checks.x86_64-linux` in
  `flake.nix`.
- Docs: `doc/technical_details/sandboxing.md` ("CI side: runtime probe"
  section), `doc/technical_details/workflow-mechanics.md` (workflow table);
  README map unchanged (no new files).
- No module, option, or consumer-facing API changes; consumer workflows are
  unaffected (their call sites stay byte-identical).

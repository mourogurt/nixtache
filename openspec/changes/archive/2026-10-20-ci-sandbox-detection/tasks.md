# Tasks

## 1. Drift suite (test harness, red baseline)

- [x] 1.1 Create `tests/ci-workflow-drift.nix` (generic checker per
  design D4: parse the six workflow YAMLs at build time with python/pyyaml;
  assert a `sandbox-probe` step strictly precedes every step that `uses:` a
  SANDBOX_OK-consuming action or `run:`s `nix build`/`nix flake check`; assert
  vmtests.yml's suite step applies the `SANDBOX_OK`-derived flag) and wire it
  into `checks.x86_64-linux.ci-workflow-drift` in `flake.nix`. Verify the red
  baseline: `nix build .#checks.x86_64-linux.ci-workflow-drift` fails today,
  naming the `ci.yml`, `vmtests.yml` and `docs.yml` violations.

## 2. Workflow fixes

- [x] 2.1 In `.forgejo/workflows/ci.yml`, move the `sandbox-probe` step to
  directly after checkout (before "Verify flake metadata") so
  `flake-validation`'s `nix flake check` sees the real `SANDBOX_OK`. Verify
  the drift suite's `ci.yml` assertions turn green.
- [x] 2.2 In `.forgejo/workflows/vmtests.yml`, add a `sandbox-probe` step
  after checkout and derive `SANDBOX_FLAG` in the "Run VM suite" step exactly
  like ci.yml's module-test step, applying it to the `nix build -L` line.
  Verify the drift suite's `vmtests.yml` assertions turn green.
- [x] 2.3 In `.forgejo/workflows/docs.yml`, insert a `sandbox-probe` step
  between the nixtache checkout and `generate-docs`. Verify the whole drift
  suite is green: `nix build .#checks.x86_64-linux.ci-workflow-drift && cat
  ./result` shows ok for all workflows.

## 3. Specs and documentation

- [x] 3.1 Widen the purpose paragraph of `openspec/specs/ci-workflows/spec.md`
  in place (design D5): the capability covers CI workflows nixtache ships,
  reusable or self-CI. Verify `openspec show ci-workflows --type spec` reads
  coherently with the delta's widened requirement.
- [x] 3.2 Update `doc/technical_details/sandboxing.md` ("CI side: runtime
  probe" — all six workflows probe first, incl. vmtests.yml's inline flag and
  docs.yml) and `doc/technical_details/workflow-mechanics.md` (inventory rows
  for `docs.yml`, `ci.yml`, and a new `vmtests.yml` row), keeping links to
  `openspec/specs/ci-workflows/spec.md`; check `doc/user_guide/docs.md` for
  stale docs.yml mechanics claims and fix if present. Verify no doc still
  claims docs/vmtests builds always run `--no-sandbox` or that ci.yml probes
  after validation (`rg -n 'no-sandbox|sandbox-probe|SANDBOX_OK' doc/`).
- [x] 3.3 Add `ci-workflow-drift` to the `checks.<system>` suite list in
  `README.md` (repository map). Verify the map's suite list matches
  `flake.nix`.

## 4. Integration checks

- [x] 4.1 Run `nix flake check --show-trace --all-systems` locally and verify
  it is green (drift suite included via `checks.*`).
- [x] 4.2 Run `openspec validate ci-sandbox-detection --strict` and verify it
  passes.

## Workflow follow-up

- Archive the change after the review requirements are satisfied
  (`/opsx-archive`).
- After merge, watch the first `ci.yml` and `vmtests.yml` runs on the real
  runners: the ci.yml `nix flake check` now builds sandboxed on healthy
  runners — confirm no latent sandbox-only failure surfaces (design Risks).

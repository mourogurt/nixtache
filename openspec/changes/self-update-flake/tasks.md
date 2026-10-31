# Tasks

## 1. Reusable update profiles

- [x] 1.1 Extend `.forgejo/workflows/update-flake.yml` with optional `runner` and `validation-profile` inputs for both `workflow_call` and `workflow_dispatch`, defaulting to `nixos` and `consumer`, and use `inputs.runner` for `runs-on`; parse the YAML to verify both trigger defaults and the runner expression.
- [x] 1.2 Validate `validation-profile` in the existing guard after creating `artifacts/`, accepting only `consumer` and `nixtache-self`, and add the consumer-profile condition only to the configuration and devShell rebuild steps; verify by parsing the workflow that update, flake validation and push retain profile-independent conditions.
- [x] 1.3 Extend `tests/ci-workflow-drift.nix` with assertions for reusable/manual defaults, accepted-profile validation, rebuild conditions and unchanged shared steps; run `nix build .#checks.x86_64-linux.ci-workflow-drift` and confirm the report passes.
- [x] 1.4 Update `doc/technical_details/workflow-mechanics.md` with the optional runner/profile contract and a link to `openspec/specs/ci-workflows/spec.md`; verify the documented defaults and step behavior match the parsed workflow and that existing consumer wrappers need no changes.

## 2. Nixtache self-update caller

- [x] 2.1 Create `.forgejo/workflows/self-update.yml` with `workflow_dispatch`, weekly cron `15 4 * * 1`, and one call to `nixops/nixtache/.forgejo/workflows/update-flake.yml@main` using `runner: test` and `validation-profile: nixtache-self`; parse the YAML to verify the triggers, reference and inputs.
- [x] 2.2 Add `self-update.yml` assertions to `tests/ci-workflow-drift.nix` for its schedule, manual trigger, reusable-workflow target and self inputs; run `nix build .#checks.x86_64-linux.ci-workflow-drift` and confirm both consumer-default and self-update contracts pass.
- [x] 2.3 Update the `README.md` workflow map, the `workflow-mechanics.md` self-update inventory/runner-label sections, and `doc/GLOSSARY.md` with the flake-versus-host self-update distinction, linking the functional behavior to `openspec/specs/ci-workflows/spec.md`; verify every edited statement matches the workflow YAML and every added relative link resolves.

## 3. Integration and rollout verification

- [x] 3.1 Run `openspec validate self-update-flake --strict` and `nix flake check --show-trace --all-systems`; confirm both complete successfully without changing unrelated checks.
- [ ] 3.2 After the combined change reaches `main`, confirm the external `test` runner has the required credentials and repository write permission without logging secret material, then manually dispatch `self-update.yml`; verify the `test` label, shared credential/logging behavior, successful flake checks, skipped consumer rebuilds, and an SSH-signed lock-file commit when inputs change.

# Tasks

## 1. Sandbox probe in update-flake

- [x] 1.1 Add a `sandbox-probe` step to `.forgejo/workflows/update-flake.yml` after "Setup Git" and before "Update Flakes Inputs", using `./.nixtache/.forgejo/actions/sandbox-probe` with `if: steps.guard.outputs.enabled == 'true'`; verify by reading the file that the step sits before the first nix invocation and carries the guard condition
- [x] 1.2 Verify sandbox semantics: with the probe in place, `SANDBOX_OK=1` on a sandbox-capable runner makes `flake-validation`, `rebuild-configurations` and `rebuild-devshells` omit `--no-sandbox` (trace the env flow in the three action.yml files)

## 2. Failure-log capture

- [x] 2.1 In `.forgejo/actions/flake-validation/action.yml`, tee `nix flake check --show-trace --all-systems $SANDBOX_FLAG` output to `artifacts/flake-check.log` (create `artifacts/` first, preserve console output and the non-zero exit on failure); verify the failure path still exits 1 and the log file is written on both success and failure paths
- [x] 2.2 In `.forgejo/workflows/update-flake.yml`, tee the "Update Flakes Inputs" step output to `artifacts/flake-update.log` (with `set -o pipefail` semantics so a failed update still fails the step); verify a failing `nix flake update` both exits non-zero and leaves the log
- [x] 2.3 In `.forgejo/workflows/update-flake.yml`, create `artifacts/` unconditionally in the guard step (runs in both enabled and disabled modes) so the always-run "Deploy artifacts" upload never hits a missing path; verify by inspection that no earlier step can fail leaving `artifacts/` absent

## 3. Documentation

- [x] 3.1 Update the `update-flake.yml` row of the inventory table in `doc/technical_details/workflow-mechanics.md` to mention `sandbox-probe` before builds and log capture into `artifacts/`, linking `openspec/specs/ci-workflows/spec.md`; verify the row matches the post-change workflow
- [x] 3.2 Check `README.md` workflow/action map entries for `update-flake.yml` and `flake-validation`; update wording only if the map describes probe/logging behavior; verify no fact is duplicated (map links, mechanics doc owns the detail)

## 4. Validation

- [x] 4.1 Run `openspec validate fix-update-flake-logs-sandbox --strict` and confirm it passes
- [x] 4.2 Run `nix flake check --show-trace --all-systems` to confirm the repo's own CI surface is untouched (no module changes); verify it passes
- [x] 4.3 YAML-lint the two edited workflow/action files (e.g. `nix run nixpkgs#yamllint -- -d relaxed .forgejo/workflows/update-flake.yml .forgejo/actions/flake-validation/action.yml` or python `yaml.safe_load` round-trip); verify they parse

## Workflow follow-up

- Trigger `update-flake` manually in a consumer repo (e.g. `codemaster/nixos-configuration`) and confirm: probe line appears, a forced failure leaves `flake-update.log`/`flake-check.log` in the `logs` artifact.
- Archive the change after the project's review requirements are satisfied.

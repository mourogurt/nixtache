# Tasks

## 1. ssh-setup multi-bundle support

- [x] 1.1 Extend `.forgejo/actions/ssh-setup/action.yml`: `creds` input accepts a space-separated list; loop over bundles, copy each present key pair, and write one `Host` block with one `IdentityFile` line per available bundle (per-bundle warn-and-skip, `required: true` escalates); verify by shelling the script logic locally with a fake `CREDENTIALS_DIRECTORY` containing both/one/no bundles and inspecting the generated config
- [x] 1.2 Set outputs per design D2 (`key-path`/`config-path` = update key when listed, else first available bundle; `User` line = `NIXTACHE_UPDATE_GIT_USER` when update listed, else flake user, else `git-user` input); verify the single-bundle invocations in `nix-check.yml` and `deploy.yml` still produce byte-identical configs to before (regression check)

## 2. update-flake guard + fetch wiring

- [x] 2.1 Reorder `.forgejo/workflows/update-flake.yml`: githost and `ssh-setup` (now `creds: "flake update"`, unconditional) move before the guard; verify the file reads checkout → checkout nixtache → githost → ssh-setup → guard → Setup Git → sandbox-probe → update → …
- [x] 2.2 Extend the guard step: keep the env-absent → `enabled=false` branch; when the env is present, probe with `timeout 30 git ls-remote "ssh://${NIXTACHE_UPDATE_GIT_USER}@${{ steps.githost.outputs.host }}/${GITHUB_REPOSITORY}" HEAD` and `exit 1` with `::error::` on failure; verify by inspection that a publickey failure path exits non-zero at the guard and that all later steps keep their `if: steps.guard.outputs.enabled == 'true'` conditions
- [x] 2.3 In "Update Flakes Inputs", after the tee to `artifacts/flake-update.log`, grep the log for `^error: Failed to fetch|Permission denied|Could not read from remote` and exit 1 on match; verify a simulated log containing run 907's lines fails the step while a clean log passes

## 3. Documentation

- [x] 3.1 Update `doc/technical_details/module-ci-wiring.md`: guard now probes the update credential (`ls-remote` over the push URL), and update-flake consumes both `flakeSshCreds` and `updateSshCreds`; verify the credential table row and the self-disable paragraph match the new behavior and link `openspec/specs/ci-workflows/spec.md`
- [x] 3.2 Update the `update-flake.yml` row in `doc/technical_details/workflow-mechanics.md` (guard probes credential; flake+update SSH bundles); verify no duplication with module-ci-wiring.md
- [x] 3.3 Check `doc/user_guide/quickstart.md` `updateSshCreds` comment (line ~45) and add one line that private flake inputs require `flakeSshCreds` in update-flake too; verify the sentence links to the secrets/creds doc rather than duplicating it

## 4. Validation

- [x] 4.1 Run `openspec validate fix-update-flake-guard-creds --strict` and confirm it passes
- [x] 4.2 YAML-parse the two edited files (`python3 -c "import yaml,sys; yaml.safe_load(open(f))"`); verify both parse
- [x] 4.3 Run `nix flake check --show-trace --all-systems`; verify it passes (no module changes expected) — the run fails only at `checks.x86_64-linux.ab-contract`, which fails identically with this change's files reverted (pre-existing failure of the parallel in-flight work in the tree; this change touches no Nix surface)

## Workflow follow-up

- Trigger `update-flake` manually in `codemaster/nixos-configuration` (private `nixtache` input) and confirm: fetch succeeds with the flake key, and a revoked key fails at the guard, not at push.
- Archive the change after the project's review requirements are satisfied.

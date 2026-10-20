# Tasks

## 1. ssh-setup multi-host support

- [x] 1.1 Extend `.forgejo/actions/ssh-setup/action.yml`: `git-host` accepts a space-separated list; loop hosts and write one `Host` block per host (own `HostName`, own optional `Port` from a `host:port` token, shared `User` + all `IdentityFile` lines per block); verify with the local harness (fake `CREDENTIALS_DIRECTORY`) that a two-host invocation yields two blocks each carrying both keys, and that single-host invocations stay byte-identical to `git show HEAD:.forgejo/actions/ssh-setup/action.yml` behavior
- [x] 1.2 Update the `git-host` input description to document the list form and per-host `:port` handling; verify the description matches the implemented splitting

## 2. update-flake host derivation

- [x] 2.1 In `.forgejo/workflows/update-flake.yml`, turn "Derive git host" into "Derive git hosts": start from `NIXTACHE_GIT_SSH_HOST`, add every SSH host from `jq -r '.nodes[].locked.url // empty' flake.lock` (strip `git+` prefix, `ssh://user@` part; keep `:port` if present), dedupe, output space-separated `hosts`; verify the guard probe and Push Changes still use the FIRST host (`${{ steps.githost.outputs.… }}` first token or a separate `push-host` output)
- [x] 2.2 Pass the derived host list to `ssh-setup` (`git-host: ${{ steps.githost.outputs.hosts }}`); verify by reading the file that no step other than the probe/push references the old single-host output
- [x] 2.3 Re-run the harness scenario from 1.1 with the run-955 shape (hosts `zinzaguras.ru` + `code.zinzaguras.ru`, both cred bundles) and verify both blocks carry `IdentityFile` lines, the update user, and no port leakage between blocks

## 3. nix-check: drop the hardcoded host

- [x] 3.1 In `.forgejo/workflows/nix-check.yml`, replace `git-host: code.zinzaguras.ru` with the same lock-derived host list (inline derivation step before `Setup SSH`, prepending `NIXTACHE_GIT_SSH_HOST` with `GITHUB_SERVER_URL`-hostname fallback for runners without the env); verify no vendor-specific hostname remains anywhere under `.forgejo/` (`grep -rn 'zinzaguras' .forgejo/` is empty)

## 4. Documentation

- [x] 4.1 Update `doc/technical_details/workflow-mechanics.md`: describe the host derivation (push host + `flake.lock` ssh hosts) once in the mechanics section and trim the `nix-check.yml`/`update-flake.yml` table rows to link it; verify no duplication with module-ci-wiring.md
- [x] 4.2 Update `doc/technical_details/module-ci-wiring.md`: note that workflows derive the SSH host list from `flake.lock` + `NIXTACHE_GIT_SSH_HOST`, and that `gitHost.hostNames` must cover every hostname nix contacts (known_hosts); verify the existing `gitHost.hostNames[0]` row still matches (it feeds `NIXTACHE_GIT_SSH_HOST` only)

## 5. Validation

- [x] 5.1 Run `openspec validate fix-update-flake-ssh-hosts --strict` and confirm it passes
- [x] 5.2 YAML-parse every edited file (`python3 -c "import yaml; yaml.safe_load(open(f))"`); verify all parse
- [x] 5.3 Dry-run the derivation snippet against a `flake.lock` fixture containing `ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git`, `git+ssh://forgejo@code.zinzaguras.ru/codemaster/nixos-private.git`, and a `github:...` tarball input; verify the output is exactly `zinzaguras.ru code.zinzaguras.ru` (with the push host first) and github/https inputs contribute nothing
- [x] 5.4 Run `nix flake check --show-trace --all-systems`; verify no NEW failures vs the pre-existing parallel-WIP `ab-contract` failure (isolate by stashing this change's files if in doubt)

## Workflow follow-up

- Trigger `update-flake` in `codemaster/nixos-configuration` and confirm run 955's failure is gone: private inputs fetch via the flake key, update step green.
- Do NOT archive before that live run is green.
- Archive the change after the project's review requirements are satisfied.

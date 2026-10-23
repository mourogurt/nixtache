# Tasks

## 1. Option surface + registration wiring

- [x] 1.1 Rework `instanceType` in `modules/runner/types.nix`: add required
  `uuid` (runner UUID from Forgejo), remove `name`, rewrite `tokenFile`
  description to the bare-token contract (no `TOKEN=` prefix); verify with
  `nix-instantiate --parse modules/runner/types.nix`
- [x] 1.2 Rewrite the container config in `modules/runner/instances.nix`
  onto `services.forgejo-runner`: connection `default` with
  `url = forgejoUrl` + per-instance `uuid`, token via
  `secrets.server.connections.default.token_url` at the existing bind-mount
  path, `labels` → `settings.runner.labels`, keep `enable`/`hostPackages`
  and the `runner.envs`/timeout/log settings passthrough; verify with
  `nix-instantiate --parse modules/runner/instances.nix`
- [x] 1.3 In `modules/runner/instances.nix`, append
  `forgejo-runner-<iname>` to the container's `nix.settings.trusted-users`
  for every enabled instance; drop the static `gitea-runner` entry from the
  base container config in `modules/runner/default.nix` and update the
  `package` option description (references `services.forgejo-runner.package`
  now); verify with `nix-instantiate --parse modules/runner/default.nix`

## 2. Sub-module service-name rewrites

- [x] 2.1 Rename the LoadCredential/BindPaths/ordering target units from
  `gitea-runner-<iname>` to `forgejo-runner-<iname>` in
  `modules/runner/{ssh,store,deploy,ab}.nix` (and their comments); verify
  with `nix-instantiate --parse` on all four files and
  `grep -rn "gitea-runner" modules/` returning no live hits

## 3. Tests

- [x] 3.1 Update `tests/runner.nix` scaffolding to the new in-container
  surface (`services.forgejo-runner.instances`, `forgejo-runner-*` unit
  names) and extend every existing scenario (store, multi-instance, ssh,
  sandbox, cache, deploy) to assert against it — including uuid/connection
  wiring, per-instance token bind mounts, labels location, and
  trusted-users; verify with `nix build .#checks.x86_64-linux.runner`
- [x] 3.2 Add a failing-eval scenario to `tests/runner.nix`: setting
  `instances.default.name` fails evaluation, and `uuid` is required
  (absent → eval error); verify via the same suite build

## 4. Documentation

- [x] 4.1 Rewrite the registration part of `doc/user_guide/quickstart.md`:
  uuid + token model (each instance its own registration), the bare-token
  file format, the one-time migration (extract `uuid`/`token` from
  `/var/lib/gitea-runner/<name>/.runner` in the old container) and creating
  a fresh registration in Forgejo; link to
  `openspec/specs/runner/spec.md`; verify every snippet against the final
  option surface
- [x] 4.2 Update stale references: `README.md` map line for `runner`
  (`services.forgejo-runner`, uuid+token), `doc/technical_details/
  {module-ci-wiring,resources,testing}.md` unit names and the
  `gitea-actions-runner` map mention; check `doc/GLOSSARY.md` for terms
  naming the old registration model and sharpen them; verify with
  `grep -rn "gitea-actions-runner\|gitea-runner" README.md doc/user_guide
  doc/technical_details` returning only intentional historical mentions
- [x] 4.3 Rebuild the generated option reference and confirm the new
  `uuid` option and reworded descriptions pass strict docs mode; verify
  with `nix build .#optionsMarkdown`

## 5. Integration checks

- [x] 5.1 Full flake validation; verify with
  `nix flake check --show-trace --all-systems`
- [x] 5.2 Confirm no vmTest suite or workflow asserts on the old runner
  surface; verify with `grep -rn "gitea-runner\|gitea-actions-runner"
  tests/ .forgejo/` returning no hits and `.forgejo/workflows/vmtests.yml`
  suite list unchanged

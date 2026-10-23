# Proposal

## Why

nixpkgs 26.11 removed `services.gitea-actions-runner` outright: evaluating
the runner container now fails with a fatal assertion ("Running
forgejo-runner via `services.gitea-actions-runner' is no longer supported.
Please use `services.forgejo-runner' instead."). NixOS container configs
evaluate against the *consumer's* nixpkgs, so every consumer on current
nixpkgs is broken — observed live on a `nixos-configuration` `server`
toplevel build. The replacement `services.forgejo-runner` module is not a
rename: it redesigns runner registration (uuid + token pair instead of
self-registration via a registration token), renames the runner services
and state directories, and drops the static `gitea-runner` account.

## What Changes

- Switch the in-container runner wiring (`modules/runner/instances.nix`)
  from `services.gitea-actions-runner` to `services.forgejo-runner`.
- **BREAKING** registration model: `instances.<name>.tokenFile` no longer
  holds a `TOKEN=`-prefixed registration token for self-registration. New
  required per-instance option `uuid`; the token file must contain the bare
  runner token obtained from Forgejo (runners no longer self-register).
  Wired to `settings.server.connections.default.{url,uuid}` +
  `secrets.server.connections.default.token_url`.
- **BREAKING** `instances.<name>.name` removed: runners no longer
  self-report their name; the name is fixed when the registration is
  created in Forgejo.
- In-container service rename `gitea-runner-<name>` →
  `forgejo-runner-<name>` across all sub-module wiring (ssh, store, deploy,
  ab LoadCredentials / BindPaths); state moves to
  `/var/lib/forgejo-runner/<name>`.
- Container nix `trusted-users`: replace the removed static `gitea-runner`
  account with the per-instance NSS-visible dynamic service users
  (`forgejo-runner-<name>`), so host-mode jobs stay trusted nix clients.
- Tests: re-target wiring assertions at the new module surface (uuid, token
  path, labels location, connection map, service names, trusted-users).
- Docs: quickstart registration section (uuid + token acquisition,
  including extracting the pair from an existing `.runner` file), README
  map, technical docs referencing `gitea-runner-*` units.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `runner`: add requirements for the uuid + token registration wiring, the
  instance option surface tracking the upstream `forgejo-runner` module,
  the container nix daemon trusting the runner service users, and the
  registration-migration documentation.

## Impact

- Code: `modules/runner/{instances,types,default,ssh,store,deploy,ab}.nix`.
- Tests: `tests/runner.nix` (all scenarios asserting on service names /
  instance wiring).
- Docs: `README.md` (map), `doc/user_guide/quickstart.md`,
  `doc/technical_details/{module-ci-wiring,resources,testing}.md`.
- Consumers: one-time migration per runner instance (obtain uuid + bare
  token — from Forgejo or the old `.runner` file) before the first deploy
  of the updated module; requires a Forgejo instance supporting the new
  runner registration model.

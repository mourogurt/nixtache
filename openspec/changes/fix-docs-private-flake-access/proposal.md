# Proposal

## Why

The reusable `docs.yml` workflow builds the caller's flake without configuring the `flake` SSH credential bundle, so a documentation build can fetch private inputs only when a usable revision is already cached on the runner. Any lock-file change that requires a fresh private-input fetch can therefore fail documentation generation with SSH authentication errors, while public-input builds remain unaffected.

## What Changes

- Configure `docs.yml` to derive the SSH host list from the runner's canonical git host and the caller's locked `git+ssh://`/`ssh://` input URLs, then run `ssh-setup` with the `flake` credential bundle before building documentation.
- Preserve the existing optional-credential behavior: runners without `flakeSshCreds` warn and continue so flakes with only public inputs still build.
- Add pure-eval regression coverage that pins the docs workflow's private-input credential setup, host derivation, and ordering before `generate-docs`.
- Update the workflow and documentation-generation guides to describe private-input fetching for documentation builds.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ci-workflows`: extend the private-input fetch and SSH-host requirements to cover documentation builds, including graceful behavior when no flake credential is configured.

## Impact

- `.forgejo/workflows/docs.yml`: add runtime git-host derivation and `ssh-setup` before the docs build; existing workflow inputs, artifacts, sandbox probing, and build behavior remain unchanged.
- `tests/ci-workflow-drift.nix`: add build-cheap assertions against the real workflow YAML.
- Documentation: `doc/technical_details/workflow-mechanics.md`, `doc/technical_details/module-ci-wiring.md`, `doc/technical_details/testing.md`, and `doc/user_guide/docs-generation.md`.
- No module options, caller workflow interfaces, deployment workflows, or secret-storage behavior change. Consumers with private inputs must already provide `flakeSshCreds`, as for `nix-check.yml`; no migration is required.

# Proposal

## Why

The reusable `update-flake.yml` automates consumer flakes, but nixtache has no
scheduled path for updating its own `flake.lock`; its self-CI runs on pushes,
pull requests and manual dispatch only. Running the consumer pipeline unchanged
would also impose consumer-oriented NixOS configuration and devShell rebuilds,
so nixtache needs the same update safety guarantees with validation suited to
this flake.

## What Changes

- Add a thin nixtache-owned self-update workflow with scheduled and manual
  triggers that calls the shared update pipeline instead of duplicating it.
- Make `update-flake.yml` support a self-validation profile: consumer callers
  retain their current configuration and devShell rebuilds by default, while
  nixtache self-updates run flake validation without those consumer-only
  rebuilds.
- Keep credential guarding, private-input SSH setup, sandbox probing,
  fetch-error detection, signed bot commits, update/check logs and artifact
  upload common to consumer and self-update runs.
- Add workflow contract coverage and update the maintained workflow and self-CI
  documentation. Existing consumer wrappers must continue to work unchanged.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ci-workflows`: cover scheduled and manual nixtache self-updates through the
  shared update pipeline, including profile-appropriate validation, preserved
  consumer defaults and the existing credential, signing and diagnostic
  guarantees.

## Impact

- `.forgejo/workflows/update-flake.yml`: reusable validation behavior for both
  consumer and nixtache self-update callers.
- A new thin self-update workflow under `.forgejo/workflows/`: nixtache-owned
  schedule and manual entry point.
- `tests/ci-workflow-drift.nix` and focused workflow contract tests: coverage
  for the self-update path and unchanged consumer defaults.
- `README.md`, `doc/technical_details/workflow-mechanics.md` and affected
  self-CI/testing documentation: workflow inventory and current behavior.
- No new NixOS module options or changes to consumer wrapper call sites are
  anticipated.

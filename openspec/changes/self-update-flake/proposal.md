# Proposal

## Why

The reusable `update-flake.yml` automates consumer flakes, but nixtache has no
scheduled path for updating its own `flake.lock`; its self-CI runs on pushes,
pull requests and manual dispatch only. Running the consumer pipeline unchanged
would also impose consumer-oriented NixOS configuration and devShell rebuilds,
so nixtache needs the same update safety guarantees with validation suited to
this flake.

LFS-enabled workflows must select a transport supported by the current Forgejo
instance instead of assuming that the checkout's HTTPS endpoint can transfer
LFS objects. Nixtache self-update also needs its KVM-only `vmTests` gate:
`nix flake check` deliberately excludes those suites, so flake validation alone
cannot establish that an updated lock is safe to push.

## What Changes

- Add a thin nixtache-owned self-update workflow with scheduled and manual
  triggers that calls the shared update pipeline instead of duplicating it.
- Make `update-flake.yml` support a self-validation profile: consumer callers
  retain their current configuration and devShell rebuilds by default, while
  nixtache self-updates run flake validation without those consumer-only
  rebuilds and run the full VM test inventory when KVM is available.
- Add shared Git LFS transport selection to LFS-enabled reusable workflows.
  Prefer pure SSH when available, retain HTTPS as a fallback, respect explicit
  repository LFS configuration, and keep the selected transport effective for
  both fetches and update pushes.
- Select an online `kvm` runner when available and fall back to `test`
  otherwise. Run the full `vmTests.x86_64-linux` inventory against the updated
  checkout before pushing when `/dev/kvm` is usable; any VM failure blocks the
  lock-file commit, while unavailable KVM records a skip and does not prevent
  the update.
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
  shared update pipeline, including profile-appropriate validation, the full
  pre-push VM gate, instance-appropriate Git LFS transport, preserved consumer
  defaults and the existing credential, signing and diagnostic guarantees.

## Impact

- `.forgejo/workflows/update-flake.yml`: reusable validation behavior for both
  consumer and nixtache self-update callers, including the self-only VM gate.
- A new thin self-update workflow under `.forgejo/workflows/`: nixtache-owned
  schedule and manual entry point with online-`kvm` discovery and `test`
  fallback.
- `.forgejo/workflows/nix-check.yml`, `deploy.yml`, `docs.yml` and
  `update-flake.yml`, plus a shared composite action: deferred LFS transfer and
  instance-appropriate SSH/HTTPS selection.
- `tests/ci-workflow-drift.nix` and focused workflow contract tests: coverage
  for the self-update path, unchanged consumer defaults, VM ordering and LFS
  transport selection.
- `README.md`, `doc/technical_details/workflow-mechanics.md` and affected
  self-CI/testing documentation: workflow inventory and current behavior.
- No new NixOS module options or changes to consumer wrapper call sites are
  anticipated.

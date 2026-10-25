# Proposal

## Why

The non-AB audit found implementation defects behind contracts that already
exist: the deploy SSH gate can execute shell suffixes, manual-user validation
is vacuous, the sandbox probe can be satisfied from cache, slow cache fills
can escape request coalescing, and early CI failures can lose artifacts or
suppress the remaining suite reports. These defects affect deploy security
and the reliability of routine CI, independently of the A/B migration work.

## What Changes

- Restrict the deploy gate's `nix-store --serve` acceptance to the exact
  protocol forms used by `nix copy`; reject shell chaining, redirection and
  other suffixes, with negative execution tests.
- Stop augmenting a hand-managed deploy user through `users.users.<name>`:
  add pointer-group membership through `users.groups` so the existing
  missing-user assertion and diagnostic actually work.
- Make every sandbox probe realize a per-run unique derivation, so a cached or
  substituted output cannot masquerade as a fresh runtime probe; retain the
  `SANDBOX_OK` fallback contract.
- Align nginx cache-lock age/timeout behavior for slow NAR generation and add
  a concurrency test proving the existing single-upstream requirement.
- Create `artifacts/` before fallible setup in reusable workflows and make
  self-CI print every obtainable suite report before returning a collected
  failure instead of stopping at the first failing step/suite.
- Update the affected technical docs and tests without changing public module
  option shapes or the A/B/overlay scope owned by `server-ab-migration-prep`
  and `wipe-on-cutover`.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `deploy-user`: concrete rejection and diagnostic scenarios for the existing
  exact-protocol and manual-user requirements.
- `runner-cache`: a slow-fill concurrency scenario for the existing
  single-upstream coalescing requirement.
- `ci-workflows`: fresh-per-run sandbox probing and early artifact-directory
  scenarios.
- `docs`: a failure-path scenario requiring all obtainable suite reports in
  self-CI.

## Impact

- `modules/deploy-target/user.nix` and `tests/deploy-target.nix`: gate and
  manual-user behavior.
- `.forgejo/actions/sandbox-probe/action.yml`,
  `.forgejo/workflows/{nix-check,update-flake,ci}.yml`,
  `.forgejo/actions/flake-validation/action.yml`: probe and failure reporting.
- `modules/runner/cache.nix` and its cache tests: lock configuration and
  slow-fill coalescing.
- `tests/ci-workflow-drift.nix` and relevant maintained technical docs.
  No AB/CA VM suites are needed for these fixes; their verification stays out
  of this change.

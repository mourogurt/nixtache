# Design

## Context

See `proposal.md` for motivation and `specs/ci-workflows/spec.md` for the behavior contract. `docs.yml` already checks out both the caller and nixtache before `generate-docs`; `nix-check.yml` and `update-flake.yml` already establish the credential and host-derivation pattern. The existing `ssh-setup` action supports the `flake` bundle and treats missing credentials as optional by default. `tests/ci-workflow-drift.nix` already parses the real workflow YAML in a build-cheap check.

## Goals / Non-Goals

**Goals:**

- Reuse the established private-input credential path without changing the reusable workflow's inputs or artifact contract.
- Cover the canonical runner git host and every SSH host recorded in the caller's `flake.lock` before Nix evaluates or builds the requested docs outputs.
- Pin the wiring and step ordering with a pure-eval regression check.

**Non-Goals:**

- Do not change `ssh-setup`, `generate-docs`, runner credential options, deployment workflows, or caller wrappers.
- Do not refactor `nix-check.yml` or `update-flake.yml` to extract a shared host-derivation helper as part of this fix.
- Do not add a live private-repository dependency to the pure-eval test suite.

## Decisions

### D1: Mirror the established workflow wiring

Add the same host derivation used by `nix-check.yml`, followed by `ssh-setup` with `creds: flake`, after both checkouts and before sandbox probing and documentation generation. The caller checkout makes `flake.lock` available; the nixtache checkout makes the composite action available. Reusing this sequence keeps fetch behavior consistent across building workflows.

A hardcoded git host would miss locked aliases. Moving credential setup into `generate-docs` would mix repository transport setup into an otherwise reusable docs builder. Extracting a new shared host-derivation action would create a third workflow refactor and broaden the regression surface beyond this fix; that remains a separate maintenance option.

### D2: Keep flake credentials optional

Use `ssh-setup`'s default `required: false` behavior and add no workflow inputs or secrets. Public-only flakes continue on runners without `flakeSshCreds`, with the action's existing warning. Private-input flakes still require the consumer to configure `flakeSshCreds` and matching known-host entries; the workflow must not hide an actual fetch failure or fall back to cached content as a success contract.

Making the credential mandatory for every docs run would break public-only consumers and is therefore rejected.

### D3: Extend the existing workflow-drift check

Parse `docs.yml` in `tests/ci-workflow-drift.nix` and assert that host derivation consumes the checked-out lock file, `ssh-setup` receives the derived host list and only the `flake` bundle, and setup precedes `generate-docs`. Also retain the existing sandbox-probe ordering assertion. Static checks provide deterministic coverage without encoding credentials or requiring network access; an uncached private-input run remains the end-to-end validation scenario.

## Risks / Trade-offs

- [Host-derivation logic now exists in three workflows] → The drift check pins the docs copy to the same inputs and wiring; any future deduplication must preserve all three contracts.
- [A derived SSH host without a matching known-host key still fails verification] → Document the existing `gitHost`/`extraKnownHosts` requirement rather than disabling host-key verification.
- [Static YAML checks cannot prove server authorization] → Keep the private-input scenario explicit and validate through the normal reusable-workflow CI path when credentials are available.

## Migration Plan

No consumer migration is required. Callers using the reusable workflow from `main` receive the fix on their next docs run; callers pinned to another ref opt in by updating that ref. Rollback is a revert of the workflow and regression-check changes, with no runner or state migration.

# Design

## Context

See `proposal.md` — Why. The mechanics today: the `sandbox-probe` composite
action exports `SANDBOX_OK` to `GITHUB_ENV`; every build action
(`flake-validation`, `rebuild-configurations`, `rebuild-devshells`,
`generate-docs`, `deploy-target`) and ci.yml's inline module-test loop read it
and append `--no-sandbox` unless it equals `1`. `nix-check.yml`,
`update-flake.yml` and `deploy.yml` already probe before their first build
step; `ci.yml` probes *after* `flake-validation`, `vmtests.yml` and `docs.yml`
never probe. Workflow files are plain YAML — the repo already has a pure-eval
pattern for pinning their content (`tests/ab-deploy-drift.nix` reads the real
`action.yml` at build time and asserts on its text).

## Goals / Non-Goals

**Goals:**

- One uniform rule, checkable in CI: every workflow nixtache ships probes the
  sandbox before its first `SANDBOX_OK`-consuming step (composite action or
  inline `nix build` / `nix flake check`).
- A build-cheap pure-eval suite that fails when a workflow regresses the
  ordering, so the contract does not depend on reviewer attention.

**Non-Goals:**

- No changes to the `sandbox-probe` action itself, to the
  `SANDBOX_OK`-reading logic inside the composite actions, or to any module.
- No new composite action wrapping `nix build` (one consumer in `vmtests.yml`
  does not justify a new action; the inline conditional matches ci.yml's
  module-test step).
- No consumer-facing workflow interface changes (inputs, triggers, call sites
  stay identical).

## Decisions

### D1: `ci.yml` — move, don't duplicate

Move the existing `sandbox-probe` step to directly after checkout, before
"Verify flake metadata" — mirroring `nix-check.yml`'s order (probe →
metadata → validation). `nix flake metadata` does not build, so the exact
position relative to it is behaviorally neutral; placing the probe first
keeps all six workflows on one canonical shape ("probe is the first step
after checkouts") and removes the special case. A second probe step was
rejected: `SANDBOX_OK` is job-env state, two probes mean two throwaway
builds and a misleading "which one counts" question.

### D2: `vmtests.yml` — inline flag, per-job probe

Add `sandbox-probe` after checkout (unconditional), and in the "Run VM suite"
step derive `SANDBOX_FLAG` exactly like ci.yml's module-test step does
(`SANDBOX_OK=1` → empty, else `--no-sandbox`), applying it to the
`nix build -L` line. The probe runs once per matrix job, not once per
workflow: sandbox health is a property of the specific runner the job landed
on (the `kvm` label may map to several machines), so a shared
`needs:`-prefixed probe job would assert the wrong machine. Cost is one
unique-name `runCommand` build per job — seconds. The probe also runs on
matrix entries whose suite step is skipped by the smoke filter; accepted as
noise for simplicity (the alternative — copying the four-line `if:` filter
onto the probe — couples the probe to the filter logic).

### D3: `docs.yml` — probe between checkouts and `generate-docs`

Insert `sandbox-probe` after the nixtache checkout, before `generate-docs`.
`generate-docs` already reads `SANDBOX_OK` with the `:-0` default, so no
action change is needed — today's always-`--no-sandbox` behavior simply
becomes conditional on the probe.

### D4: drift suite — extend the `ab-deploy-drift` pattern, generic checker

New suite `tests/ci-workflow-drift.nix` wired into
`checks.x86_64-linux.ci-workflow-drift` (build-cheap: file reads + a
python/pyyaml pass, same tooling `ab-deploy-drift.nix` already uses). It
parses each of the six workflow YAMLs at build time and asserts:

- every step that `uses:` a `SANDBOX_OK`-consuming action or `run:`s
  `nix build` / `nix flake check` has a strictly earlier `sandbox-probe`
  step in the same job;
- `vmtests.yml`'s suite step actually consumes the flag (its run text
  references `SANDBOX_OK` and applies the flag variable to `nix build`).

A generic ordering rule (data-driven over a list of the six files) instead of
per-file assertions, so a future workflow fails the suite the moment it adds
a build step without a probe. Alternative considered: YAML linting in CI
(actionlint/yamllint) — rejected, it checks syntax, not this contract, and
lives outside the flake's checked outputs.

### D5: main-spec purpose widened in-place

The `ci-workflows` capability's purpose says "reusable CI workflows"; the
widened contract covers nixtache's own CI too. Purpose text is not carried by
deltas, so the purpose paragraph of `openspec/specs/ci-workflows/spec.md` is
edited directly during implementation (one sentence: from "reusable CI
workflows" to "CI workflows nixtache ships, reusable or self-CI"); the
requirement change itself travels through this change's delta and archives
normally.

## Risks / Trade-offs

- [Generic checker couples to step-shape heuristics] → The consumer set
  (`uses:` five known actions; `run:` matching `nix build|nix flake check`)
  is explicit and small; a new consumption shape simply needs one list entry.
- [Probe adds seconds to every vmtests matrix job, incl. skipped ones] →
  one uncached `runCommand` per job; negligible next to multi-minute VM
  suites.
- [ci.yml `nix flake check` becomes truly sandboxed on healthy runners] →
  first run after this change may surface latent sandbox-only build failures
  that `--no-sandbox` was masking; that is the point of the probe, and the
  fallback path still exists for broken runners.

## Migration Plan

Workflow-file edits only; merging to `main` activates them (runners pick the
workflow from the ref they run against). Rollback = revert the commit. No
host rebuild, no runner-module change, consumers unaffected.

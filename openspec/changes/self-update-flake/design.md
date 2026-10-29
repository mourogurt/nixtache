# Design

## Context

See `proposal.md` — Why and `specs/ci-workflows/spec.md` for the behavioral
contract.

`update-flake.yml` currently runs on the fixed `nixos` label and always runs
the consumer configuration and devShell rebuild actions. Nixtache's own CI uses
the dedicated `test` label and deliberately omits those rebuilds: the only
NixOS configuration is a dogfood fixture, and `flake-validation` already builds
the flake's `checks.*` through `nix flake check`.

The reusable workflow owns credential setup, updating, validation, signed push
and diagnostics. Trigger policy belongs to its caller, while its composite
actions are resolved from a separate `nixops/nixtache` checkout pinned to
`main`.

## Goals / Non-Goals

**Goals:**

- Keep one update pipeline and make runner selection and validation depth
  explicit, optional caller inputs with backward-compatible defaults.
- Keep nixtache's schedule and runner policy in a thin self-owned caller.
- Test the real workflow YAML so consumer defaults and self-update wiring
  cannot drift silently.

**Non-Goals:**

- No consumer wrapper migration, new NixOS module options or credential
  changes in this repository.
- No duplication of the update pipeline or conversion of `ci.yml` into a
  reusable workflow.
- No changes to host/A-B auto-update behavior or KVM VM suites.

## Decisions

### 1. Add a thin self-update caller

Create `.forgejo/workflows/self-update.yml` with `workflow_dispatch` and a
weekly schedule (`15 4 * * 1`, Monday at 04:15 UTC). Its only job calls
`nixops/nixtache/.forgejo/workflows/update-flake.yml@main` with the self runner
and validation inputs described below.

A separate full workflow would duplicate the credential, update, signing and
logging logic. Putting the schedule directly in `update-flake.yml` would mix
nixtache's maintenance policy into the consumer-facing reusable workflow and
encourage repository-name conditionals. A thin caller preserves the existing
rule that schedules belong to callers.

The self caller uses the same `@main` reusable-workflow reference as consumers.
Scheduled self-updates therefore use the published workflow and composite
actions together; manual verification of this change happens after merge, on
`main`.

### 2. Parameterize runner and validation profile

Add optional `workflow_call` inputs to `update-flake.yml`:

- `runner`: string, default `nixos`; used as `runs-on: ${{ inputs.runner }}`.
- `validation-profile`: string, default `consumer`; accepted values are
  `consumer` and `nixtache-self`.

Define matching manual-dispatch defaults so directly dispatched consumer runs
keep their current behavior. The self caller sets `runner: test` and
`validation-profile: nixtache-self`.

The existing guard rejects an unknown validation profile before update work,
after ensuring the artifact directory exists. Only the two consumer rebuild
steps gain an additional `validation-profile == 'consumer'` condition. Checkout,
SSH setup, credential guard, sandbox probe, flake update, flake validation,
signed push and artifact upload remain profile-independent.

Explicit inputs are preferable to inferring self mode from the repository name:
consumer defaults remain visible and other repositories cannot accidentally
acquire nixtache-specific behavior.

### 3. Reuse flake validation rather than self-CI

The `nixtache-self` profile skips only `rebuild-configurations` and
`rebuild-devshells`. It still runs `flake-validation`, which evaluates the
flake and builds all `checks.*` before the push. The normal push-triggered
`ci.yml` remains responsible for detailed suite reports and generated-option
artifacts, so the update path does not duplicate the full self-CI job.

Calling `ci.yml` from the update path would require making it reusable and
would couple lock maintenance to unrelated reporting and documentation steps;
that is unnecessary for the pre-push validation gate.

### 4. Extend the existing workflow contract suite

Extend `tests/ci-workflow-drift.nix` rather than adding another check output.
In addition to the existing sandbox-ordering checks, its Python YAML assertions
will pin:

- both reusable and manual defaults (`nixos`, `consumer`);
- the two allowed self-caller input values (`test`, `nixtache-self`);
- schedule and manual triggers on `self-update.yml`;
- consumer-only conditions on both rebuild steps, with update, flake validation
  and push remaining independent of the profile.

These are cheap static contracts over the real files, not VM scenarios.

Update the README workflow map and `workflow-mechanics.md` with the caller and
input behavior. Use “flake self-update” where necessary to distinguish this CI
concept from host self-update, and record that distinction in `doc/GLOSSARY.md`.

## Risks / Trade-offs

- [A missing or mistyped default silently reduces consumer validation] →
  Declare defaults for both call and dispatch triggers, reject unknown
  profiles, and assert defaults plus step conditions in `ci-workflow-drift`.
- [The `test` runner lacks update credentials or the bot lacks write access] →
  Verify the external runner and repository permission before enabling the
  schedule; retain the existing no-op/fail-fast credential guard and manually
  dispatch once before relying on scheduled runs.
- [A self caller and the reusable workflow resolve different revisions] → Use
  the established `@main` reference for both workflow and actions, and treat
  `main` as the supported self-update target; verify only after the combined
  change lands.
- [Concurrent pushes make the update push non-fast-forward] → Let the push fail
  without bypassing validation or force-pushing; retain logs and rerun the
  workflow after the branch settles.

## Migration Plan

1. Confirm that the external `test` runner provides the required flake/update
   credentials and that the update key can write to `nixops/nixtache`; store no
   credentials in this repository.
2. Merge the reusable inputs and thin caller together. Existing consumers need
   no edits because both new inputs default to current behavior.
3. Manually dispatch `self-update.yml` on `main`; verify use of the `test`
   runner, skipped consumer rebuilds, successful flake checks, uploaded logs
   and an SSH-signed lock-file commit when inputs change.
4. To roll back, disable or remove `self-update.yml`. The optional reusable
   inputs can remain without affecting consumers; revert any unwanted lock
   commit separately through normal git history.

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

LFS-enabled workflows currently let `actions/checkout` fetch LFS objects before
the existing SSH setup runs. The checkout remote can therefore select HTTPS
even when the instance supports pure-SSH LFS or when its HTTPS endpoint is not
reachable from the runner. Transport selection must happen after credentials
are available but before any LFS objects are fetched.

`vmTests.x86_64-linux` is intentionally excluded from `checks.*` because it
requires KVM. The `test` and `kvm` labels select distinct runner registrations.
KVM is optional in nixtache deployments, so self-update must remain usable when
no online `kvm` runner exists or the selected runner has no usable `/dev/kvm`.

## Goals / Non-Goals

**Goals:**

- Keep one update pipeline and make runner selection and validation depth
  explicit, optional caller inputs with backward-compatible defaults.
- Keep nixtache's schedule and runner policy in a thin self-owned caller.
- Select a working Git LFS transport without hardcoding a Forgejo instance,
  while preserving explicit repository configuration and HTTPS fallback.
- Gate nixtache's self-update push on the full VM inventory built from the
  updated checkout when KVM is available, without making KVM mandatory for
  flake self-update.
- Test the real workflow YAML so consumer defaults, self-update wiring, LFS
  setup and validation ordering cannot drift silently.

**Non-Goals:**

- No consumer wrapper migration, new NixOS module options or credential
  changes in this repository.
- No duplication of the update pipeline or conversion of `ci.yml` into a
  reusable workflow.
- No changes to host/A-B auto-update behavior or the existing scheduled/manual
  `vmtests.yml` matrix.

## Decisions

### 1. Add a thin self-update caller

Create `.forgejo/workflows/self-update.yml` with `workflow_dispatch` and a
weekly schedule (`15 4 * * 1`, Monday at 04:15 UTC). A small preflight job on
`test` discovers an online `kvm` candidate through the Forgejo runners API and
falls back to `test` when discovery fails or no such runner is online. A second
short job probes `/dev/kvm` on that candidate and selects `test` if the device
is unusable. API authentication uses a short-lived OIDC JWT for an optional
Forgejo Authorized Integration whose non-secret audience comes from the
`NIXTACHE_RUNNER_DISCOVERY_AUDIENCE` repository variable; an unconfigured or
denied integration retains the `test` fallback. The update job calls
`nixops/nixtache/.forgejo/workflows/update-flake.yml@main` with the final
selected runner and validation inputs described below.

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
keep their current behavior. The self caller forwards its preflight's `kvm` or
`test` selection as `runner` and sets `validation-profile: nixtache-self`;
consumer defaults remain `nixos` and `consumer`.

The existing guard rejects an unknown validation profile before update work,
after ensuring the artifact directory exists. Only the two consumer rebuild
steps gain an additional `validation-profile == 'consumer'` condition. Checkout,
SSH setup, credential guard, sandbox probe, flake update, flake validation,
signed push and artifact upload remain profile-independent.

Explicit inputs are preferable to inferring self mode from the repository name:
consumer defaults remain visible and other repositories cannot accidentally
acquire nixtache-specific behavior.

### 3. Combine flake validation with a self-only VM gate

The `nixtache-self` profile skips only `rebuild-configurations` and
`rebuild-devshells`. It still runs `flake-validation`, which evaluates the
flake and builds all `checks.*`. The normal push-triggered `ci.yml` remains
responsible for detailed suite reports and generated-option artifacts, so the
update path does not duplicate the full self-CI job.

Flake validation is not sufficient for nixtache's own lock updates because it
excludes `vmTests`. After flake validation and before `Push Changes`, the self
profile checks for a usable `/dev/kvm`. When present, it discovers and builds
the full `vmTests.x86_64-linux` inventory in the same updated workspace with at
most three concurrent suites. Discovering attributes from the flake avoids
maintaining a second copy of the `vmtests.yml` matrix. A failed suite blocks the
push, and each VM transcript is retained with the update artifacts. When KVM is
unavailable, the step writes a skip diagnostic and exits successfully without
discovering or building suites so hosts without KVM can still self-update. The
consumer profile never runs this nixtache-specific gate.

Runner discovery keeps the update job itself from waiting indefinitely for an
optional runner label. API failure selects the safe `test` fallback rather than
blocking self-update. The candidate capability probe handles an online runner
whose label promises KVM but whose device is not exposed to jobs. A runner that
goes offline after discovery can still leave the probe or update job queued
until Forgejo retries or the run is cancelled.
Calling the existing `vmtests.yml` as a separate workflow would not provide the
required ordering: its fresh checkout and independent matrix cannot validate
the updated lock between the update and push steps without splitting and
transferring workflow state. Its scheduled and dispatch behavior remains
unchanged.

### 4. Extend the existing workflow contract suite

Extend `tests/ci-workflow-drift.nix` rather than adding another check output.
In addition to the existing sandbox-ordering checks, its Python YAML assertions
will pin:

- both reusable and manual defaults (`nixos`, `consumer`);
- online-`kvm` API discovery with `test` fallback in the self caller, the
  `nixtache-self` profile, and the schedule/manual triggers;
- consumer-only conditions on both rebuild steps, with update, flake validation
  and push remaining independent of the profile;
- usable-`/dev/kvm` gating and full VM discovery after flake validation and
  before push for the self profile, a successful skip when KVM is unavailable,
  and no VM step in the consumer profile;
- deferred LFS fetching and transport setup in every LFS-enabled workflow,
  with transport selection after SSH setup and before build/update work.

These are cheap static contracts over the real files, not VM scenarios. Focused
transport tests exercise SSH preference, HTTPS fallback, explicit repository
configuration and the no-working-transport failure without contacting a real
Forgejo instance. The post-merge self-update run exercises the actual KVM
inventory when available and the recorded skip path otherwise.

Update the README workflow map and `workflow-mechanics.md` with the caller,
input behavior, LFS transport and validation ordering. Use “flake self-update”
where necessary to distinguish this CI concept from host self-update, and record
that distinction in `doc/GLOSSARY.md`.

### 5. Select Git LFS transport after SSH setup

For `nix-check.yml`, `deploy.yml`, `docs.yml` and `update-flake.yml`, the initial
caller checkout uses `lfs: false`. Once the existing nixtache checkout and SSH
setup have completed, a shared composite action selects the transport and
fetches the caller's LFS objects before any build or update step needs them.

An explicit repository LFS URL remains authoritative. Otherwise the action
probes pure-SSH LFS using the configured credentials and prefers it when
usable; if pure SSH is unavailable, it probes and retains the HTTPS LFS API.
The selected endpoint is configured locally so subsequent LFS fetches and the
update push use the same transport. If neither transport works, the action
fails with an endpoint-and-transport diagnostic that contains no credentials.

This ordering avoids `actions/checkout` eagerly fetching over an unsuitable
HTTPS endpoint, while keeping public HTTPS-only consumers functional. Transport
probing and endpoint construction derive repository/host information from the
runner and checkout context rather than embedding a server-specific URL.

## Risks / Trade-offs

- [A missing or mistyped default silently reduces consumer validation] →
  Declare defaults for both call and dispatch triggers, reject unknown
  profiles, and assert defaults plus step conditions in `ci-workflow-drift`.
- [The selected runner lacks update credentials or branch protection rejects
  the bot's push] → Verify the `test` runner and any optional `kvm` runner,
  repository permission and branch protection before enabling the schedule;
  retain the existing no-op/fail-fast credential guard and manually dispatch
  once before relying on scheduled runs.
- [A transport probe rejects a usable endpoint or selects an unreachable one] →
  Respect explicit repository configuration, prefer a verified pure-SSH
  endpoint, retain HTTPS fallback and fail before build/update work with a
  redacted diagnostic when neither transport works.
- [The full VM inventory exceeds the update runner's capacity] → Reuse the
  bounded-concurrency policy of the existing VM workflow where practical,
  retain per-suite logs and let failures block the push rather than weakening
  the gate.
- [A self caller and the reusable workflow resolve different revisions] → Use
  the established `@main` reference for both workflow and actions, and treat
  `main` as the supported self-update target; verify only after the combined
  change lands.
- [Concurrent pushes make the update push non-fast-forward] → Let the push fail
  without bypassing validation or force-pushing; retain logs and rerun the
  workflow after the branch settles.

## Migration Plan

1. Confirm that the `test` runner and any optional `kvm` runner provide the
   required flake/update credentials and that branch protection allows the
   update bot to write to `nixops/nixtache`; store no credentials in this
   repository.
2. Merge the reusable inputs, LFS transport selection and thin caller together.
   Existing consumers need no wrapper edits because both new inputs default to
   current behavior and HTTPS LFS fallback remains available.
3. Manually dispatch `self-update.yml` on `main`; verify preflight runner
   selection, selected LFS transport, skipped consumer rebuilds, successful
   flake checks and, when KVM is available, the full VM inventory. On a host
   without KVM, verify the recorded VM skip instead. Check uploaded logs and an
   SSH-signed lock-file commit when inputs change.
4. To roll back self-update, disable or remove `self-update.yml`. The optional
   reusable inputs can remain without affecting consumers; revert any unwanted
   lock commit separately through normal git history. LFS transport selection
   can be reverted independently if a consumer instance proves incompatible.

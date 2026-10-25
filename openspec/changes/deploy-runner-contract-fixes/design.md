# Design

## Context

See proposal.md — Why. The affected contracts already exist; this change fixes
their implementation and regression coverage. Work is deliberately independent
of the AB/CA suites and the overlay lifecycle changes.

## Goals / Non-Goals

**Goals:**

- Make the deploy gate fail closed for every unapproved shell form while
  preserving valid `nix copy` transport.
- Restore meaningful manual-user validation and fresh runtime probing.
- Preserve single-upstream NAR coalescing during slow fills.
- Keep early-failure artifacts and all obtainable CI suite reports.

**Non-Goals:**

- No new public options, credential bundles or deployment protocols.
- No AB/overlay changes, percentage-size work, or CA/KVM verification.
- No weakening of the existing canonical requirements to match current bugs.

## Decisions

### D1 — Validate serve commands, then exec them directly

Replace the `nix-store --serve*` prefix match with exact matches for the serve
forms used by `nix copy` (initially `nix-store --serve` and
`nix-store --serve --write`; add another only when a protocol test proves it is
required). Execute an accepted form directly as the store-path `nix-store`
binary with a fixed argument vector, not by passing the original string to
`shell -c`. Pointer and A/B commands keep their existing exact validators and
approved `&&`/redirection forms.

This removes the injection boundary rather than trying to sanitize shell
metacharacters. Rejection tests cover `;`, `&&`, redirection, command
substitution and extra arguments. Acceptance coverage distinguishes a rejected
command from a serve process that starts and exits at protocol EOF; the real
`nix copy` path remains the compatibility check.

Alternative considered: a restricted serve regex executed through `shell -c` —
rejected because a shell is unnecessary for this command and is harder to prove
safe against every parser expansion.

### D2 — Manual group membership uses `users.groups`

With `autoProvision = true`, keep the current system-user declaration. With
`autoProvision = false`, remove the module's `users.users.${du.name}` block and
use `users.groups.nixtache-deploy.members = [ du.name ]` for pointer-directory
access. The existing `config.users.users ? ${du.name}` assertion then tests a
consumer declaration rather than the module's own augmentation.

Tests assert the exact missing-user message, membership on a manually declared
user, and unchanged normal-user/key warnings.

### D3 — Every sandbox probe gets a fresh output name

Generate a unique probe name for every action invocation from the run id,
attempt, PID and random shell value. Pass it through the environment and read
it with `builtins.getEnv` in the already-impure expression, avoiding Nix-string
injection and shared outputs across jobs. A second invocation must therefore
execute `mkdir -p $out` even when an earlier probe's output is present.

Keep `SANDBOX_OK=1` as "the fresh build succeeded without explicit
`--no-sandbox`", not as proof that sandboxing is enabled. Failure still selects
`0` and the fallback. Static workflow tests pin the absence of a fixed probe
name and the per-run environment plumbing; a lightweight action harness runs
the probe twice and checks that the output names differ.

### D4 — Lock slow NAR fills for the configured upstream window

Set `proxy_cache_lock_age` alongside the existing `proxy_cache_lock_timeout`
and `proxy_read_timeout`, initially `300s` for all three in both NAR and
narinfo locations. This removes the much shorter nginx default lock age while
retaining bounded waits. Update option descriptions only with the actual
bounded semantics.

Add a non-KVM integration check using a local nginx configuration and a slow
local upstream delayed for 30 seconds. Concurrent requests for one uncached
NAR must produce one upstream request and all clients must receive the filled
response. Pure-eval assertions pin all three directives; the runtime check
owns the concurrency proof. No CA appliance image or KVM VM is involved.

### D5 — Artifact creation precedes fallible setup

In `nix-check.yml` and `update-flake.yml`, create `artifacts/` immediately
after the two checkouts and before host derivation, SSH setup and the probe.
Keep the defensive `mkdir` in `flake-validation` for other callers. Workflow
static tests assert this ordering; early setup failures then always reach the
upload with a directory present.

### D6 — Self-CI collects failures after reporting

Give flake validation an id and `continue-on-error: true`. Run the suite-report
step with `if: always()`, derive the suite list from
`checks.x86_64-linux` when evaluable, and remove `set -e` from the loop. Each
suite records its status independently; print its report whenever an output
exists and continue. The step exits non-zero only after the loop if validation
or any suite failed. Docs generation may remain skipped on failure; the
always-run upload still executes.

This favors complete diagnostics over fail-fast reporting and keeps the suite
inventory from drifting when `ab-contract` or another check is registered.

### D7 — Verification stays lightweight

Use `tests/deploy-target.nix` for gate/manual-user behavior,
`tests/ci-workflow-drift.nix` for workflow ordering and probe wiring, and the
new non-KVM cache integration check for slow fills. Do not add AB/CA variants
or require a local `nix flake check` world rebuild; the affected cheap suites
run directly in CI, with static OpenSpec validation available locally.

## Risks / Trade-offs

- [An unlisted legitimate serve form is rejected] → initially accept only the
  two known forms, exercise real `nix copy`, and expand only from captured
  protocol evidence.
- [Unique probe outputs accumulate in the runner store] → outputs are tiny and
  follow normal Nix GC; uniqueness is required for a meaningful runtime probe.
- [Longer cache locks hold clients during a stalled fill] → retain the 300s
  bound and stale-serving; test a slow fill, not an indefinitely stuck backend.
- [Reporting every suite takes longer on failure] → accept it for diagnosability;
  no successful-suite work is duplicated merely to satisfy the reporting loop.

## Migration Plan

No consumer configuration migration is required. Deploy targets receive the
gate/membership fix through their normal module rebuild; valid deploy commands
are unchanged. Runner/nginx and workflow changes roll out independently.
Rollback restores the previous module/workflows but also restores the known
defects, so the gate fix should take precedence operationally.

## Open Questions

(none)

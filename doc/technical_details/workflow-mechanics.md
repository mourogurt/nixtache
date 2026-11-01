# Reusable workflow mechanics (Forgejo)

How nixtache's reusable workflows and composite actions resolve at run time.
Source of truth: [`.forgejo/workflows/`](../../.forgejo/workflows/) and
[`.forgejo/actions/`](../../.forgejo/actions/).

## Caller-context execution

A reusable workflow (`on: workflow_call`) invoked from a caller repo runs in
the **caller's** checkout context: `actions/checkout@v4` checks out the
caller, so `nix flake show` / `nix build .#X` see the caller's flake — this
is why consumer wrappers need no `with:` inputs for the flake itself.

## Action resolution via `.nixtache/`

To resolve **this repo's** composite actions, every reusable workflow checks
out `nixops/nixtache` into `.nixtache/` (pinned to `main`) and uses
`./.nixtache/.forgejo/actions/<name>`. This is robust against Forgejo's
cross-repo action path resolution — a workflow file that references a local
`./.forgejo/actions/...` path resolves relative to the *caller's* checkout,
which would not contain the action.

## Two-job rendering

In the Forgejo UI a reusable call renders as two jobs: `<name>` (0s, the
caller) and `<name>-1` (the actual work). Expected, not a bug.

## SSH host derivation

Jobs that touch git over SSH pass `ssh-setup` a runtime-derived host list
instead of a hardcoded hostname: the **push host** from
`NIXTACHE_GIT_SSH_HOST` (falling back to the bare `GITHUB_SERVER_URL`
hostname when that env is unavailable — an HTTP endpoint, its port stripped)
plus every `ssh://`/`git+ssh://` host in the checked-out `flake.lock`
(`locked.url` entries; `git+`/`ssh://` scheme and `user@` stripped, `:port`
kept), deduplicated. `flake.lock` is the authoritative record of the hosts nix
will contact — including aliases of the same git server — and ssh offers the
loaded keys only to hosts with a `Host` block. `ssh-setup` writes one `Host`
block per listed host; the update-key guard and the push always target the
push host (the first entry). Every contacted hostname must have a matching key
in the effective known-hosts configuration (`gitHost` or `extraKnownHosts`;
see [module-ci-wiring.md](module-ci-wiring.md)).

## Git LFS transport

The LFS-enabled reusable workflows (`nix-check.yml`, `deploy.yml`, `docs.yml`
and `update-flake.yml`) check out the caller with `lfs: false`. After
`ssh-setup` and before any build or update work, the shared `lfs-fetch` action
selects a transport and runs the explicit `git lfs pull`.

An explicitly configured repository endpoint remains authoritative: the action
does not replace `lfs.url`, `lfs.pushurl`, `remote.<name>.lfsurl` or
`remote.<name>.lfspushurl`, whether configured in Git configuration or
`.lfsconfig`. Without an explicit endpoint, it first configures the derived
repository SSH URL locally with `lfs.sshtransfer=always` and attempts the pull;
`always` prevents an implicit downgrade to the hybrid SSH/HTTPS protocol. If
that fetch fails, it configures the caller's HTTPS LFS API endpoint locally and
retries. A failure of both transports stops the workflow before build/update
work. Diagnostics identify the unsuccessful transports while endpoint command
output is captured and credential material is redacted.

The selected local endpoint is retained after the fetch, so later LFS pushes
use the same transport; in particular, changing the Git `origin` URL in
`update-flake.yml`'s `Push Changes` step does not discard the separate
`lfs.url`. Canonical requirements:
[`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md).

## Inventory

| Workflow | Purpose | Notable mechanics |
|---|---|---|
| `nix-check.yml` | flake validation + rebuild all `nixosConfigurations` + `x86_64-linux` devShells | `ssh-setup` (creds: `flake`) with the [derived host list](#ssh-host-derivation) for private inputs; `sandbox-probe` before builds |
| `deploy.yml` | direct deploy to targets | `concurrency: deploy-<ref>`, never auto-cancelled; mode derived from the branch inside the action (PR → dry-activate, main → switch); pre-copy disk-space gate on `live` targets with nonzero `minFreeBytes` + workspace-pinned `UserKnownHostsFile` (no HOME dependency) — canonical requirements: [`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md) |
| `docs.yml` | build + upload doc artifacts | `workflow_call` inputs `attributes` (default `docs`) and `artifact-name`; manual dispatch exposes only `attributes`; `ssh-setup` (creds: `flake`, optional — runners without `flakeSshCreds` warn and continue) with the [derived host list](#ssh-host-derivation) before `generate-docs`, so uncached private flake inputs fetch; `sandbox-probe` before `generate-docs`; canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |
| `update-flake.yml` | `nix flake update --commit-lock-file`, validate, push signed bot commit | optional inputs `runner` (default `nixos`) and `validation-profile` (default `consumer`): `consumer` keeps flake validation + the NixOS configuration and devShell rebuilds, `nixtache-self` skips the two consumer rebuilds and, after flake validation, runs the full `vmTests.x86_64-linux` inventory before push when `/dev/kvm` opens read/write (or records a successful skip otherwise); the guard rejects any other profile value before update work; guard step self-disables when `NIXTACHE_UPDATE_GIT_USER` is absent (`updateSshCreds = null`), otherwise probes the update key with `git ls-remote` before the pipeline (semantics: [module-ci-wiring.md](module-ci-wiring.md)); `ssh-setup` wires both `flake` and `update` bundles into one SSH config with the [derived host list](#ssh-host-derivation); the update step greps its log for fetch errors nix downgrades to warnings and fails on them; `sandbox-probe` before builds (same `SANDBOX_OK` self-heal as `nix-check.yml`); `flake update` + `flake check` output teed into `artifacts/` (`flake-update.log`, `flake-check.log`) for the always-run upload; **the `schedule` trigger must live in the caller's wrapper** — a schedule here would update nixtache's own flake, not the caller's — canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |
| `ci.yml` (self-CI, not reusable) | validate nixtache itself | runs on the dedicated `test` runner label; `sandbox-probe` first, before the `flake-validation` build; prints every `checks.*` suite report; generates the `nixtache-options` artifact |
| `vmtests.yml` (self-CI, not reusable) | run the KVM-only `vmTests` inventory | manual dispatch (full/smoke or one `suite`) + nightly-smoke/weekly-full schedules on the `kvm` label; `sandbox-probe` once per matrix job, the suite `nix build` applies the `SANDBOX_OK`-derived flag (see [sandboxing.md](sandboxing.md)); runner prerequisites: [testing.md](testing.md) |
| `self-update.yml` (self, not reusable) | nixtache's own flake self-update: scheduled + manual bump of this flake's `flake.lock` | a `test`-runner preflight uses an optional OIDC Authorized Integration to query the repository runners API and selects an online `kvm` candidate, falling back to `test` when discovery is unconfigured or denied, or when none is online; a capability probe on the candidate also selects `test` when `/dev/kvm` is unusable, then the update job calls `update-flake.yml@main` with the final runner, `validation-profile: nixtache-self` and `secrets: inherit`; `workflow_dispatch` + weekly schedule `15 4 * * 1` (Monday 04:15 UTC) — canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |

Composite actions: `ssh-setup` (parameterised `git-host` list — one `Host`
block per host, see [SSH host derivation](#ssh-host-derivation) — `creds:
flake|update`; exports `key-path`), `lfs-fetch` (see
[Git LFS transport](#git-lfs-transport)), `sandbox-probe` (exports
`SANDBOX_OK`), `flake-validation`, `rebuild-configurations`,
`rebuild-devshells`, `generate-docs`, `deploy-target`.

## Runner labels

The reusable workflows `nix-check.yml`, `deploy.yml` and `docs.yml` are fixed
to `runs-on: nixos` (the consumer's default runner instance label);
`update-flake.yml` runs on its optional `runner` input (default `nixos`), so
a caller can move the pipeline to another registered label without touching
the reusable workflow. Nixtache's `ci.yml` runs on `test` (the
`instances.test` label `test:host`). `self-update.yml` runs discovery on `test`,
probes the selected candidate for `/dev/kvm` opened read/write, and passes the
final online-`kvm` selection or `test` fallback to the reusable update job. The
self profile runs VM suites only when the update runner exposes that device;
otherwise it records the skip and continues without making a KVM registration
mandatory. Labels are properties of the runner registration, not of the
workflows.

Runner discovery uses Forgejo's OIDC support rather than the unsupported
workflow `permissions` field (which Forgejo ignores with a warning). To allow
it to see online runners, create a **Forgejo Actions (Local)** [Authorized
Integration](https://forgejo.org/docs/v17.0/user/api/authorized-integrations/)
as a user with repository administration rights (repository write alone cannot
list runners) for source repository `nixops/nixtache`, workflow file `self-update.yml`, Git
reference `refs/heads/main` and events `schedule` + `workflow_dispatch`, with
`read:repository` capability on `nixops/nixtache`. Set the repository Actions
variable `NIXTACHE_RUNNER_DISCOVERY_AUDIENCE` to the generated audience; this
identifier is not confidential. The workflow requests a short-lived JWT for
that audience and uses it only in the runners API Authorization header. A
missing audience, unavailable OIDC or denied API request produces a warning and
selects `test`, so self-update still works without this optional integration.

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

## Inventory

| Workflow | Purpose | Notable mechanics |
|---|---|---|
| `nix-check.yml` | flake validation + rebuild all `nixosConfigurations` + `x86_64-linux` devShells | `ssh-setup` (creds: `flake`) with the [derived host list](#ssh-host-derivation) for private inputs; `sandbox-probe` before builds |
| `deploy.yml` | direct deploy to targets | `concurrency: deploy-<ref>`, never auto-cancelled; mode derived from the branch inside the action (PR → dry-activate, main → switch); pre-copy disk-space gate on `live` targets with nonzero `minFreeBytes` + workspace-pinned `UserKnownHostsFile` (no HOME dependency) — canonical requirements: [`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md) |
| `docs.yml` | build + upload doc artifacts | `workflow_call` inputs `attributes` (default `docs`) and `artifact-name`; manual dispatch exposes only `attributes`; `ssh-setup` (creds: `flake`, optional — runners without `flakeSshCreds` warn and continue) with the [derived host list](#ssh-host-derivation) before `generate-docs`, so uncached private flake inputs fetch; `sandbox-probe` before `generate-docs`; canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |
| `update-flake.yml` | `nix flake update --commit-lock-file`, validate, push signed bot commit | optional inputs `runner` (default `nixos`) and `validation-profile` (default `consumer`): `consumer` keeps flake validation + the NixOS configuration and devShell rebuilds, `nixtache-self` runs flake validation only — the two rebuild steps are the only profile-dependent ones, and the guard rejects any other profile value before update work; guard step self-disables when `NIXTACHE_UPDATE_GIT_USER` is absent (`updateSshCreds = null`), otherwise probes the update key with `git ls-remote` before the pipeline (semantics: [module-ci-wiring.md](module-ci-wiring.md)); `ssh-setup` wires both `flake` and `update` bundles into one SSH config with the [derived host list](#ssh-host-derivation); the update step greps its log for fetch errors nix downgrades to warnings and fails on them; `sandbox-probe` before builds (same `SANDBOX_OK` self-heal as `nix-check.yml`); `flake update` + `flake check` output teed into `artifacts/` (`flake-update.log`, `flake-check.log`) for the always-run upload; **the `schedule` trigger must live in the caller's wrapper** — a schedule here would update nixtache's own flake, not the caller's — canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |
| `ci.yml` (self-CI, not reusable) | validate nixtache itself | runs on the dedicated `test` runner label; `sandbox-probe` first, before the `flake-validation` build; prints every `checks.*` suite report; generates the `nixtache-options` artifact |
| `vmtests.yml` (self-CI, not reusable) | run the KVM-only `vmTests` inventory | manual dispatch (full/smoke) + nightly-smoke/weekly-full schedules on the `kvm` label; `sandbox-probe` once per matrix job, the suite `nix build` applies the `SANDBOX_OK`-derived flag (see [sandboxing.md](sandboxing.md)); runner prerequisites: [testing.md](testing.md) |
| `self-update.yml` (self, not reusable) | nixtache's own flake self-update: scheduled + manual bump of this flake's `flake.lock` | thin caller — its only job calls `update-flake.yml@main` with `runner: test`, `validation-profile: nixtache-self` (consumer rebuilds skipped, flake validation retained) and `secrets: inherit`; `workflow_dispatch` + weekly schedule `15 4 * * 1` (Monday 04:15 UTC) — canonical requirements: [`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md) |

Composite actions: `ssh-setup` (parameterised `git-host` list — one `Host`
block per host, see [SSH host derivation](#ssh-host-derivation) — `creds:
flake|update`; exports `key-path`), `sandbox-probe` (exports `SANDBOX_OK`),
`flake-validation`, `rebuild-configurations`, `rebuild-devshells`,
`generate-docs`, `deploy-target`.

## Runner labels

The reusable workflows `nix-check.yml`, `deploy.yml` and `docs.yml` are fixed
to `runs-on: nixos` (the consumer's default runner instance label);
`update-flake.yml` runs on its optional `runner` input (default `nixos`), so
a caller can move the pipeline to another registered label without touching
the reusable workflow. Nixtache's self workflows run on `test` (the
`instances.test` label `test:host`): `ci.yml` directly, `self-update.yml` via
`runner: test`. Labels are properties of the runner registration, not of the
workflows.

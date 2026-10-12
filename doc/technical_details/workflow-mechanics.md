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

## Inventory

| Workflow | Purpose | Notable mechanics |
|---|---|---|
| `nix-check.yml` | flake validation + rebuild all `nixosConfigurations` + devShells | `ssh-setup` (creds: `flake`) for private inputs; `sandbox-probe` before builds |
| `deploy.yml` | direct deploy to targets | `concurrency: deploy-<ref>`, never auto-cancelled; mode derived from the branch inside the action (PR → dry-activate, main → switch); pre-copy disk-space gate on every target + workspace-pinned `UserKnownHostsFile` (no HOME dependency) — canonical requirements: [`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md) |
| `docs.yml` | build + upload doc artifacts | `inputs.attributes` (default `docs`), `inputs.artifact-name` |
| `update-flake.yml` | `nix flake update --commit-lock-file`, validate, push signed bot commit | guard step self-disables when `NIXTACHE_UPDATE_GIT_USER` is absent (`updateSshCreds = null`); push host from `NIXTACHE_GIT_SSH_HOST`; **the `schedule` trigger must live in the caller's wrapper** — a schedule here would update nixtache's own flake, not the caller's |
| `ci.yml` (self-CI, not reusable) | validate nixtache itself | runs on the dedicated `test` runner label; prints every `checks.*` suite report; generates the `nixtache-options` artifact |

Composite actions: `ssh-setup` (parameterised `git-host`, `creds:
flake|update`; exports `key-path`), `sandbox-probe` (exports `SANDBOX_OK`),
`flake-validation`, `rebuild-configurations`, `rebuild-devshells`,
`generate-docs`, `deploy-target`.

## Runner labels

Reusable workflows `runs-on: nixos` (the consumer's default runner instance
label); nixtache's own `ci.yml` runs on `test` (the `instances.test` label
`test:host`). Labels are properties of the runner registration, not of the
workflows.

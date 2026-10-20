# Design

## Context

`ssh-setup` generates one `Host` block for one `git-host` input and points
`core.sshCommand` at it. `update-flake.yml` passes the push host derived from
`NIXTACHE_GIT_SSH_HOST` (= `gitHost.hostNames[0]`). Run 955 proved the
mismatch: keys load (no missing-bundle warnings), the guard probe on the push
host succeeds, but `nix flake update` connects to the hostname embedded in
`flake.lock` URLs — outside the `Host` block — so ssh offers only default
keys and gets `Permission denied`. `nix-check.yml` escapes the bug solely via
a hardcoded `git-host: code.zinzaguras.ru`.

See proposal.md for motivation; the `ci-workflows` delta for requirements.

## Goals / Non-Goals

**Goals:**

- update-flake fetches private inputs regardless of which hostname the lock
  file uses.
- Zero hardcoded consumer hostnames in reusable workflows.
- No behavior change for single-host `ssh-setup` callers.

**Non-Goals:**

- Changing the runner module (`gitHost`, known_hosts wiring stays).
- Teaching ssh-setup to derive hosts itself (it stays a dumb config writer;
  derivation is workflow-level).
- Touching deploy-side SSH (per-target keys, unrelated mechanism).

## Decisions

### D1: One `Host` block per listed host, not a multi-pattern `Host a b` line

A single `Host a b` line cannot carry different `Port`s per host; per-host
blocks keep the existing host:port split logic unchanged and read naturally.
Each block repeats `User` + the `IdentityFile` lines. Single-host invocations
emit exactly one block — byte-identical to today's output (regression-checked
by the local harness).

### D2: Host derivation is data-driven from `flake.lock`

`jq -r '.nodes[].locked.url // empty' flake.lock` filtered to
`ssh://`/`git+ssh://` URLs, user part stripped, deduplicated, prepended with
`NIXTACHE_GIT_SSH_HOST`. The lock file is the authoritative record of what
nix will actually contact — more reliable than any env fallback.
Alternatives considered: consumer reorders `gitHost.hostNames` (config
guessing data; also requires a runner rebuild), module exports the full
hostNames list as a new env (same rebuild problem, and the lock may contain
hosts the module does not know). The derivation runs in the workflow after
checkout, where `flake.lock` is already present.

### D3: The derivation lives inline in both workflows, not in a new action

The snippet is ~6 lines of shell used by `update-flake.yml` (githost step,
renamed) and `nix-check.yml` (replacing the hardcode). A shared composite
action for 6 lines adds inventory without removing the duplication that
matters (the hostname knowledge, which moves into `flake.lock`). If a third
consumer appears, extract then.

### D4: Guard and push keep the push host only

The credential probe and the push URL stay on `NIXTACHE_GIT_SSH_HOST`
(first list entry): push is the operation the guard exists to validate, and
`GITHUB_SERVER_URL` inside the container is `localhost:7111` (useless as a
public host), so the env-derived push host remains the canonical endpoint.

## Risks / Trade-offs

- [Lock file references a host missing from `gitHost.hostNames` known_hosts]
  → ssh fails on host-key verification with a clear message; the consumer
  must list every contacted hostname in `gitHost.hostNames` (documented
  requirement, unchanged in nature — the hardcode previously hid it for
  nix-check).
- [`ssh://user@host:port/` URLs in locks] → port stays attached to the host
  token and is split into `Port` by the existing per-block logic.
- [nix-check now depends on the derivation] → same data it already fetched
  with, minus the hardcode; verified by the run-955 log showing both
  `code.zinzaguras.ru` inputs present in the consumer's lock.

## Migration Plan

Workflow/action change pinned via `.nixtache @ main`; merging rolls out on
the next consumer run. Rollback: pin the caller's `ref` to the previous
commit.

## Open Questions

(none)

# Proposal: Disk-space gate for direct deploy

## Why

A real consumer deploy (nixos-configuration CI run 708) pushed a closure to
a target whose disk was full: `nix copy` succeeded, then activation failed
with ENOSPC inside `nixtache-apply.service`, the unit rolled back, and the
job went red with a message that pointed at the target journal rather than
the actual cause. The deploy pipeline has no notion of target disk space at
all — checks exist only in the ab-image path (`ab-provision.nix` free-space
gate). Separately, the deploy action's `ssh` calls rely on the job
environment's `HOME` for `known_hosts`: the runner job env has no `HOME`,
producing `/.ssh` warnings on every deploy and leaving target host keys
unpinned (TOFU with no persistence).

## What Changes

- **Pre-copy check (runner side)**: `_liveApply` in the `deploy-target`
  action checks the target's free store space twice: a fast pre-build refuse
  when free space is below a preset floor, and a post-build sized check —
  closure-missing-paths estimate (full-closure fallback) × 1.1 **plus the
  preset** — before `nix copy`. Fail fast with an actionable error when the
  target cannot hold the deployment.
- **Deploy-map preset**: new
  `services.nixtache.runner.deploy.targets.<name>.minFreeBytes` (default
  5 GiB, `0` disables the runner pre-copy check entirely), serialized into
  `NIXTACHE_DEPLOY_TARGETS`.
- **Apply-unit guard (target side)**:
  `services.nixtache.deploy-target.minFreeBytes` (default 5 GiB, `0`
  disables the guard); `nixtache-apply.service` checks free space before
  `nix-env --set` and exits with a clear error *without touching the system
  profile* (no rollback needed — nothing was mutated).
- **Protocol-drift tolerance**: a target whose gate predates the free-space
  query (or answers garbage) is *skipped with a per-target warning* — it
  never fails the job. Genuine failures (low disk, copy/apply errors,
  timeouts) record `::error::` per target and fail the job at the end.
  `sshGate = "restrict"` remains the transition escape hatch.
- **Gate extension** (`deploy-user`): the SSH gate whitelist learns an
  exact-match, read-only disk query command so the runner can ask the
  target for free space through the gated channel. Two-phase rollout
  documented, mirroring the `finalize-direct-deploy` protocol-drift
  guidance.
- **SSH hygiene**: the deploy action's `ssh_opts` pin
  `UserKnownHostsFile` to a workspace-local file instead of depending on
  `$HOME` — removes the `/.ssh` warnings and gives host-key verification
  a stable location per job.
- **Glossary**: `doc/GLOSSARY.md` seeds the canonical vocabulary (SSH gate,
  pre-copy disk check, apply-unit disk guard, …); a terminology rule in
  `AGENTS.md` requires checking/updating it.
- Tests for the module options and apply-unit guard; docs updated per repo
  rules.

Non-goals: changing ab-image path behavior (it already gates on space);
auto-GC or retention policy on targets (consumer-side concern — handled in
the consumer repo); fixing the runner job `HOME` itself.

## Capabilities

- **New Capabilities:** none.
- **Modified Capabilities:**
  - `direct-deploy` — new requirements: the deploy pipeline verifies target
    free space before building/copying and before activation; a target that
    cannot hold the deployment fails with a disk-space error, not a
    mid-activation ENOSPC; a target running a pre-change SSH gate is skipped
    with a warning instead of failing the job; the deploy map carries the
    per-target free-space preset.
  - `deploy-user` — the gate whitelist requirement extends to cover the
    read-only disk query command issued by the deploy action.

## Impact

- `.forgejo/actions/deploy-target/action.yml` (two-stage pre-copy check,
  drift skip, ssh opts, per-target failure collection).
- `modules/deploy-target/`: `options.nix` (minFreeBytes, unsigned),
  `apply.nix` (guard), `user.nix` (gate whitelist entry).
- `modules/runner/`: `types.nix` (deploy-map `minFreeBytes`), `deploy.nix`
  (serialization into `NIXTACHE_DEPLOY_TARGETS`).
- `doc/GLOSSARY.md` (new), `AGENTS.md` (terminology rule), `README.md`
  (documentation-layers map row).
- `tests/` (deploy-target and runner module tests; VM coverage stays in the
  action-parsing `ab-deploy` suite per precedent).
- Consumer rollout: protocol change (new gated command) requires the
  synchronized-upgrade order documented in `doc/user_guide/migration.md` §5.

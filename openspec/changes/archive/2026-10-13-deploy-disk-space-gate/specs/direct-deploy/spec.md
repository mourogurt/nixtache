# direct-deploy Delta

## ADDED Requirements

### Requirement: Pre-copy target disk-space check

The live deploy path SHALL query the target's free space on the store
filesystem through the deploy SSH channel and refuse the deployment before
any closure data is pushed when the target cannot hold it. The check is
two-stage, driven by the per-target preset
`services.nixtache.runner.deploy.targets.<name>.minFreeBytes` (default
5 GiB, serialized into `NIXTACHE_DEPLOY_TARGETS`):

1. **Pre-build**: free space below the preset fails the target immediately
   (no build, no copy).
2. **Post-build**: the deployment need is estimated as the narSize sum of
   the closure paths missing on the target × 1.1 + preset (conservative
   fallback when the remote store inventory fails: full closure size × 1.1
   + preset); free space below the need fails the target before `nix copy`.

A preset of `0` SHALL disable the pre-copy check entirely (no free-space
query is issued). Refusals SHALL be actionable errors naming the target,
available space, and required space — and SHALL NOT trigger
`nixtache-apply.service`. Per-target failures SHALL NOT abort the loop over
the remaining targets; the job SHALL fail at the end if any target errored.

#### Scenario: Nearly-full target fails before the build

- **WHEN** the target's free store space is below its preset
- **THEN** the target's deploy step errors naming target, available bytes
  and the preset — without building or copying anything

#### Scenario: Full-disk target fails before the copy

- **WHEN** the deploy action targets a machine whose store filesystem has
  less free space than the deployment requires
- **THEN** the target's deploy step exits with a disk-space error naming
  target, available and required bytes; no `nix copy` of the closure runs
  and `nixtache-apply.service` is not triggered

#### Scenario: Healthy target proceeds to activation

- **WHEN** the target's free space is sufficient for the deployment
- **THEN** the pre-copy check passes without side effects and the deploy
  continues (copy, pointer, apply trigger) as before

#### Scenario: One bad target does not starve the matrix

- **WHEN** one target fails its deploy (low disk, copy/apply error,
  timeout) while others are healthy
- **THEN** the failing target records a per-target `::error::`, the
  remaining targets deploy normally, and the job fails at the end naming
  the failed targets

#### Scenario: Protocol-drift target is skipped, job stays green

- **WHEN** the free-space query is rejected by the target's SSH gate (a
  pre-change gate during the two-phase rollout) or its answer is
  unparseable
- **THEN** the target is skipped with a per-target `::warning::` naming the
  `sshGate = "restrict"` transition hatch, and the drift alone does NOT
  fail the job

#### Scenario: Free-space query is read-only

- **WHEN** the deploy action queries the target's free space
- **THEN** the query runs through the gated deploy channel, mutates nothing
  on the target, and is rejected if its form deviates from the whitelisted
  command (see the deploy-user gate requirement)

#### Scenario: Pre-copy check disabled

- **WHEN** a target's deploy-map entry sets `minFreeBytes = 0`
- **THEN** no free-space query is issued for it and the deploy proceeds
  directly to build + copy

### Requirement: Apply-unit low-disk guard

`nixtache-apply.service` SHALL verify that free space on the store
filesystem is at least `services.nixtache.deploy-target.minFreeBytes` before
mutating the system profile. When below the threshold, the unit SHALL exit
non-zero with a message naming the deficit and recommending garbage
collection, while the system profile, `/run/current-system`, and the staged
closure remain untouched (nothing was activated, so no rollback runs). A
value of `0` SHALL disable the guard.

#### Scenario: Activation refused on a nearly-full target

- **WHEN** `nixtache-apply.service` starts with free space below
  `minFreeBytes`
- **THEN** the unit fails with a disk-space message; the previously active
  generation stays active, the pointer file is consumed, and the next deploy
  attempt after freeing space succeeds without recovery steps

#### Scenario: Guard is inert on a healthy target

- **WHEN** free space is at or above `minFreeBytes`
- **THEN** activation proceeds (profile set, switch, criticalUnits probe)
  exactly as before the guard existed

#### Scenario: Guard disabled

- **WHEN** `services.nixtache.deploy-target.minFreeBytes = 0`
- **THEN** the apply unit performs no free-space check at all

### Requirement: Deploy SSH does not depend on the job HOME

All SSH invocations the deploy action makes (probe, copy, pointer/trigger)
SHALL pin `UserKnownHostsFile` to a workspace-local path instead of relying
on the job environment's `HOME`, so host-key handling works in HOME-less
runner environments and target host keys have a stable per-job location.

#### Scenario: HOME-less runner job deploys without warnings

- **WHEN** the deploy action runs in a job environment with `HOME` unset
- **THEN** no `Could not create directory '/.ssh'` warnings appear and SSH
  host-key verification uses the workspace `known_hosts` file

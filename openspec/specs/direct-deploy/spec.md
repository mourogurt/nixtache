# direct-deploy Specification

## Purpose

Requirements for direct-deploy: deploy map → action/workflow → live apply or ab-image/OTA → auto-update. Covers dry-activation, rollback, disk-space protection, and isolation of per-target failures.

## Requirements

### Requirement: Full deploy-map serialization to env

The runner module MUST serialize `{name, enable, host, sshUser, sshPort, method, system, tags, timeout, extraOptions, minFreeBytes, hasKey}` into `NIXTACHE_DEPLOY_TARGETS` without exposing secret paths. A missing JSON key MUST be interpreted by the action as its default, not as disabled: the `enable` filter skips a target only for explicit `"enable": false`.

#### Scenario: Target with enable=true deploys through module-generated env

- **WHEN** the module is configured with `deploy.targets.<name>.enable = true` (default) and an `sshPrivateKey`, and the `deploy-target` action receives `NIXTACHE_DEPLOY_TARGETS` from the real module's `runner.envs`
- **THEN** the target is NOT skipped by the enable filter and proceeds to probe/activate

#### Scenario: Explicit enable=false is skipped with a warning

- **WHEN** the target's env JSON contains `"enable": false`
- **THEN** the action emits `skip: <name> enable=false` and continues processing other targets (CI does not fail)

#### Scenario: Module→action contract test

- **WHEN** a contract test evaluates env using the real runner module and applies the action's filters to it (no-entry / no-key / enable=false / probe)
- **THEN** the module-generated JSON includes every key read by the action (including `enable` and `extraOptions`), and the filters behave as in the scenarios above

### Requirement: Tier-1 rollback reactivates the previous configuration

On a `criticalUnits` probe failure, `nixtache-apply.service` MUST roll the system back to the pre-apply closure: `nix-env --set <prev>` AND activation via `<prev>/bin/switch-to-configuration switch`. Rollback MUST NOT use `/run/current-system/bin/switch-to-configuration`, which points to the new, broken closure after a successful switch.

#### Scenario: A switch that breaks criticalUnits rolls back without rebooting

- **WHEN** the apply unit has applied the new configuration and the `criticalUnits` probe fails within `healthCheckTimeout`
- **THEN** the live system returns to the pre-apply closure (units restart from the old closure), the apply unit exits non-zero, and the CI job fails

### Requirement: Remote A/B targets reboot after an update

For targets deployed with `method = "ab-image"` over SSH (not local-self), the action MUST wait for `systemd-sysupdate.service` to finish (`systemctl start --wait`) and then start `systemd-sysupdate-reboot.service`. The first unit only fetches and installs; the second reboots only if a newer version is installed. For local-self, idle-gated `nixtache-ab-apply` runs the same sequence to avoid interrupting the CI job.

#### Scenario: Remote target activates the new slot

- **WHEN** CI has used sysupdate to write a new image to the inactive slot of a remote A/B target
- **THEN** the target reboots and boots into the new slot without manual intervention

### Requirement: Default A/B slot labels

`ab.partitions.slot_a.label` / `slot_b.label` MUST default to `nix-store_1` / `_empty` (spec 08 §4). GPT partitions created by the provisioning script MUST have names matching the stateless-detection regular expression even when the consumer does not set labels explicitly.

#### Scenario: Provisioning without explicit labels is idempotent

- **WHEN** the consumer enables `ab.partitions` without setting `slot_a.label`/`slot_b.label`, and provisioning runs twice
- **THEN** both runs locate the slots by label (the second is a no-op), and no duplicate partitions are created

### Requirement: Gating-unit flag is consumed only on success

`nixtache-ab-apply.service` MUST remove the `ab-pending` flag file only after `systemctl start --wait systemd-sysupdate.service` succeeds. If sysupdate fails, the flag MUST remain so the next path-unit trigger retries.

#### Scenario: Failed sysupdate start preserves the signal

- **WHEN** the gating unit cannot run `systemctl start --wait systemd-sysupdate.service` (for example, the unit is masked or sysupdate fails)
- **THEN** `ab-pending` remains and the next path trigger retries

### Requirement: Slot-size mismatch stops updates

With `onSizeMismatch = "error"` and existing slot sizes that differ from the configuration, provisioning MUST report the reason and stop or mask `systemd-sysupdate.service` until manual resolution (unmask + rerun provisioning). A silent `exit 0` is forbidden.

#### Scenario: Size mismatch stops auto-update

- **WHEN** on-disk slots have the wrong size and `onSizeMismatch = "error"`
- **THEN** provisioning reports the error, `systemd-sysupdate` performs no updates until manual intervention, and the provisioning service unit fails

### Requirement: Per-target timeout is enforced

The `deploy-target` action MUST limit each target's build, copy, and activation to the deploy-map `timeout` (minutes). Exceeding it fails that target (the job fails) while other targets continue.

#### Scenario: A hung target does not block the pipeline indefinitely

- **WHEN** target activation takes longer than `timeout` minutes
- **THEN** target processing times out with an error in the log, and the pipeline exits non-zero after processing the remaining targets

### Requirement: Public deploy key is available to the job

When `deploy.targets.<name>.sshPublicKey` is set, the module MUST mount it into the container and expose it as `LoadCredential deploy_ssh_<name>.pub`, like the private key, rather than leaving the option unused.

#### Scenario: Public key is readable from the credentials directory

- **WHEN** a target is configured with `sshPublicKey` and the action's job runs
- **THEN** `$CREDENTIALS_DIRECTORY/deploy_ssh_<name>.pub` exists and contains the specified key

### Requirement: Warning when boot counting is disabled

On systemd-boot targets, the receiving `deploy-target` module MUST emit an evaluation warning when `criticalUnits` is non-empty but `boot.loader.systemd-boot.bootCounting.enable` is not enabled (Tier-0 without bootCounting cannot roll back a generation).

#### Scenario: Configuration with probe units but no bootCounting warns

- **WHEN** a systemd-boot target sets `criticalUnits = [ ... ]` without enabling bootCounting
- **THEN** configuration evaluation emits a warning connecting both facts

### Requirement: Auto-update assertions for OTA targets

On an OTA path (`method = "auto"` with an A/B target, or explicit `method = "ab-image"`), `auto-update` MUST require an image source via `services.nixtache.ab-image.enable`, `deploy-target.ab.partitions` with `source`, or a consumer-owned sysupdate transfer with `Source.Path`. Explicit `method = "ab-image"` without ab-image, ab-provision, or `systemd.sysupdate` MUST fail evaluation with a clear error.

#### Scenario: Explicit ab-image without OTA modules fails evaluation

- **WHEN** `services.nixtache.auto-update.method = "ab-image"` and the machine has neither ab-image, ab-provision, nor enabled systemd-sysupdate
- **THEN** evaluation fails with a message that the target is unsuitable for the OTA path

#### Scenario: A/B path without an image source fails evaluation

- **WHEN** auto-update selects the A/B path, but neither `ab-image.enable` nor `ab.partitions.source` is set and no consumer-owned sysupdate transfer contains `Source.Path`
- **THEN** evaluation fails with an unresolved-image-source error

### Requirement: Deploy workflow serialization

`deploy.yml` MUST declare a `concurrency.group` unique to the calling branch/repository, with `cancel-in-progress: false`: concurrent deploys of one branch queue instead of competing.

#### Scenario: Concurrent deploys of one branch do not compete

- **WHEN** two deploy runs for the same branch are active simultaneously
- **THEN** the second waits for the first (queued), and neither is automatically cancelled

### Requirement: Dry-activate runs as a root unit

`dry-activate` MUST copy the closure, write `/var/lib/nixtache/pending-dry`, and use polkit to start the root unit `nixtache-apply-dry.service`, which runs `switch-to-configuration dry-activate` and removes the pointer, without `nixos-rebuild` or sudo. The system profile, `pending-system`, and `/run/current-system` MUST NOT change.

#### Scenario: PR run shows the diff without mutating the target

- **WHEN** the action runs in `dry-activate` mode on a target
- **THEN** `nixtache-apply-dry.service` prints the `switch-to-configuration dry-activate` diff and succeeds; the system profile, `/run/current-system`, and `pending-system` are unchanged, and `pending-dry` is consumed

#### Scenario: Dry trigger has start-only polkit authorization

- **WHEN** the deploy user runs `systemctl start nixtache-apply-dry.service`
- **THEN** polkit authorizes exactly `verb=start` for this unit (alongside `nixtache-apply.service`); stop/restart and other units are rejected

#### Scenario: Gate allows the dry trigger

- **WHEN** the SSH gate (`sshGate = "gate"`) receives `echo '<storepath>' > /var/lib/nixtache/pending-dry && systemctl start nixtache-apply-dry.service` with a valid store path
- **THEN** the command is allowed; the same form with an invalid path is rejected

### Requirement: Pre-copy target disk-space check

The live deploy path SHALL check store free space through the deploy SSH
channel before building and again before copying, using the per-target
`minFreeBytes` preset (default 5 GiB; `0` disables the check). It SHALL refuse
an undersized target before `nix copy` with an actionable error and without
triggering apply. Other targets SHALL continue; the job SHALL fail at the end
if any target errored.

#### Scenario: Nearly-full target fails before the build

- **WHEN** the target's free store space is below its preset
- **THEN** the target's deploy step errors naming target, available bytes
  and the preset — without building or copying anything

#### Scenario: Full-disk target fails before the copy

- **WHEN** free space is below the post-build estimate: narSize of missing
  closure paths × 1.1 + preset (falling back to the full closure size when
  the remote inventory query fails)
- **THEN** the target's deploy step exits with a disk-space error naming
  target, available and required bytes; no `nix copy` of the closure runs
  and `nixtache-apply.service` is not triggered

#### Scenario: Healthy target proceeds to activation

- **WHEN** the target's free space is sufficient for the deployment
- **THEN** the pre-copy check passes without side effects and the deploy
  continues through copy, pointer handoff and the apply trigger

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
- **THEN** activation proceeds through profile set, switch and the
  criticalUnits probe without a disk-space refusal

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

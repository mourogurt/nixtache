# Spec Delta

## MODIFIED Requirements

### Requirement: Upper lifecycle across OTA updates is configurable

The module MUST offer an explicit lifecycle policy for the upper layer
across OTA updates (option `upperOnUpdate`): `"none"` (no lifecycle action),
`"wipe"`, and `"reconcile"`. Lifecycle actions MUST run at cutover — the
first boot into a slot whose image version differs from the version recorded
on the persistent root — and MUST NOT run on the update trigger: update
attempts that install nothing (rejected or tampered manifests, no newer
staged version, timer polls) and plain reboots on the same slot MUST leave
the upper layer and its database entries untouched.

#### Scenario: Default policy preserves current behaviour

- **WHEN** the option is not set and an OTA swap happens
- **THEN** no lifecycle action runs: upper-layer content and database
  entries are carried across the swap unchanged (the coherence hazard above
  remains the operator's concern)

#### Scenario: Wipe clears the upper layer at update cutover

- **WHEN** `upperOnUpdate = "wipe"` and the machine boots into a slot whose
  image version differs from the recorded one
- **THEN** the upper layer, its work dir and the overlay store state are
  cleared early in that boot (before the overlay mounts and the nix daemon
  starts), and the overlay comes up over the new lower with a functional
  merged store (new lower paths visible, nix usable, no stale upper content)

#### Scenario: A rejected or absent update does not wipe

- **WHEN** `upperOnUpdate = "wipe"` and an update is attempted but installs
  nothing (the manifest is rejected by signature verification, is tampered,
  or no newer version is staged — including bare `systemd-sysupdate.timer`
  ticks)
- **THEN** the upper layer, its database entries and the recorded profile
  links remain exactly as they were, and the machine keeps running the
  current slot

#### Scenario: A plain reboot keeps the upper

- **WHEN** `upperOnUpdate = "wipe"` and the machine reboots without a slot
  swap (same image version)
- **THEN** the lifecycle action does not run and upper-layer content
  persists as on any reboot

#### Scenario: Rollback boot re-applies the policy

- **WHEN** the machine rolls back to the previously blessed slot after a
  cutover already ran the lifecycle action
- **THEN** the rollback boot detects the version mismatch again: wipe is a
  no-op on the already-clean upper; reconcile re-heals against the
  now-current (older) lower

#### Scenario: Reconcile heals dangling references from the substituter

- **WHEN** `upperOnUpdate = "reconcile"`, the machine has booted into a new
  slot version, and an upper-layer tool's closure references paths missing
  from the merged view that the configured substituter can provide
- **THEN** the cutover-boot reconcile pass resolves the gc-root and profile
  targets live from the persistent root, invalidates database entries whose
  files are gone, re-fetches only the missing referenced paths, and the
  previously broken upper-layer tool runs again — without reinstalling the
  whole upper layer

#### Scenario: Reconcile degrades safely without the substituter

- **WHEN** `upperOnUpdate = "reconcile"` and a dangling reference cannot be
  re-fetched (substituter unreachable or lacks the path)
- **THEN** the reconcile unit completes the boot sequence unaffected and
  reports the unrepaired paths (failing status with a journal record naming
  them), the version marker is not written (the pass retries on the next
  boot or a manual restart), and no unrelated upper content is deleted

#### Scenario: Recorded installables are replayed after the swap

- **WHEN** `upperOnUpdate = "reconcile"` and profile installables are
  present in the persistent root's gcroots/profile links across the swap,
  whose entire closure was invalidated by the swap
- **THEN** the reconcile pass re-installs the recorded installables after
  the repair step, so the recorded user-facing tools are runnable again

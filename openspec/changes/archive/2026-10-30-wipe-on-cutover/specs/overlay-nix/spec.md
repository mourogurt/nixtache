# Spec Delta

## MODIFIED Requirements

### Requirement: Upper lifecycle across OTA updates is configurable

The module MUST offer `upperOnUpdate = "wipe"` (default) or `"reconcile"`.
Lifecycle actions MUST run at cutover — the first boot into a slot whose
image version differs from the lifecycle marker — and MUST NOT run on the
update trigger. Rejected/absent updates and same-version persistent-upper
reboots leave the upper untouched. An absent marker records a baseline
without wiping existing installs.

#### Scenario: Default policy wipes the upper layer

- **WHEN** the option is not set and the machine boots into a slot whose image
  version differs from the lifecycle marker
- **THEN** the default `"wipe"` policy clears the upper layer and its state
  before the lower DB is reseeded and the overlay mounts

#### Scenario: Wipe clears the upper layer at update cutover

- **WHEN** `upperOnUpdate = "wipe"` and the machine boots into a slot whose
  image version differs from the recorded one
- **THEN** the upper layer, its work dir and the overlay store state are
  cleared before the lower-DB loader reseeds the current slot and before the
  overlay mounts; the merged store comes up functional with no stale upper
  content

#### Scenario: A rejected or absent update does not wipe

- **WHEN** `upperOnUpdate = "wipe"` and an update is attempted but installs
  nothing (the manifest is rejected by signature verification, is tampered,
  or no newer version is staged — including bare `systemd-sysupdate.timer`
  ticks)
- **THEN** the upper layer, its database entries and the recorded profile
  links remain exactly as they were, and the machine keeps running the
  current slot

#### Scenario: A plain reboot keeps a persistent upper

- **WHEN** `upperOnUpdate = "wipe"`, the upper is on persistent storage, and
  the machine reboots without a slot swap (same image version)
- **THEN** the lifecycle action does not run and upper-layer content persists

#### Scenario: Rollback boot re-applies the policy

- **WHEN** the machine rolls back to the previously blessed slot after a
  cutover already ran the lifecycle action
- **THEN** the rollback boot detects the version mismatch again: wipe clears
  any upper content accumulated since the previous cutover, while reconcile
  re-heals against the now-current (older) lower

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
  them), the lifecycle marker is not written (the pass retries on the next
  boot or a manual restart), the lower-DB marker cannot consume that retry,
  and no unrelated upper content is deleted

#### Scenario: Recorded installables are replayed after the swap

- **WHEN** `upperOnUpdate = "reconcile"` and profile installables are
  present in the persistent root's gcroots/profile links across the swap,
  whose entire closure was invalidated by the swap
- **THEN** the reconcile pass re-installs the recorded installables after
  the repair step, so the recorded user-facing tools are runnable again

#### Scenario: Tmpfs upper reboots without stale validity records

- **WHEN** the upper resides on tmpfs and the machine reboots, with or without
  an image-version change
- **THEN** stale upper-owned Nix state is removed before the lower-DB loader
  reseeds the running slot's records, the overlay mounts clean, and no stale
  validity record remains for files lost with the tmpfs upper

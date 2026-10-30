# overlay-nix Specification

## Purpose

The writable Nix store overlay for A/B appliances (`services.nixtache.overlay-nix`):
restores ad-hoc nix usage on machines whose `/nix/store` is a read-only
squashFS/erofs image partition, defines the persistence semantics of the
writable upper layer, and owns what happens to that layer across OTA slot
updates (wipe or reconcile).

## Requirements

### Requirement: Full nix surface over a read-only store

With the overlay enabled on an A/B appliance, nix MUST be re-enabled and usable through the standard system daemon: ad-hoc realize, run, shell, build, profile install and garbage collection all operate on the merged view. Writes for paths not already valid in the lower store MUST land in the configured upper layer without mutating the lower image, and the daemon MUST enable `ca-derivations` for runtime evaluation over content-addressed closures.

#### Scenario: Install a package at runtime on an appliance

- **WHEN** a package is realized (or profile-installed) from a configured substituter on an appliance whose `/nix/store` is a read-only image
- **THEN** the package's store paths not already valid in the lower store land under the configured upper layer, the binary runs through the merged `/nix/store`, and the lower layer's content is byte-identical to the image

#### Scenario: Runtime evaluation works over the content-addressed closure

- **WHEN** a profile install evaluates nixpkgs on an appliance whose lower closure is content-addressed
- **THEN** the daemon accepts the `ca:fixed:r:` derivations (the feature is enabled in its configuration) and the install completes against the merged view

#### Scenario: The overlay is mounted before the daemon serves requests

- **WHEN** the appliance boots
- **THEN** the OverlayFS at `/nix/store` (lower = image partition, upper = configured upper layer) is active before the nix daemon serves any request, so every nix command observes the merged view

### Requirement: Runtime installs are delta against the valid lower store

With the appliance shipping a store database for the lower closure, realizing a path whose closure (or parts of it) is already valid in the lower store MUST NOT copy those paths into the upper layer; only paths missing from the merged store land in the upper.

#### Scenario: Partially-lowered closure installs as a delta

- **WHEN** a package is realized whose closure partially exists as valid entries in the lower store's database
- **THEN** the already-valid paths are served from the lower and never copied into the upper; only the missing paths are fetched into the upper layer

#### Scenario: A lower-only path needs no upper copy

- **WHEN** a store path that ships in the lower image is realized or referenced at runtime
- **THEN** no copy of it appears in the upper layer, and its validity resolves from the shipped database out of the box (no manual seeding)

### Requirement: Upper-layer persistence follows its location

The upper layer's lifetime MUST follow its configured location: on the
persistent root filesystem it survives plain reboots (content and nix
database entries); on tmpfs it is wiped by any reboot and the overlay
remounts cleanly on top of the lower image.

#### Scenario: Persistent upper survives a reboot

- **WHEN** the upper layer directory lives on the persistent root
  filesystem and the machine reboots (no update)
- **THEN** previously installed store paths remain present in the upper
  layer, still registered in the nix database, and runnable through the
  remounted merged view

#### Scenario: tmpfs upper is wiped by reboot

- **WHEN** the upper layer directory lives on tmpfs and the machine reboots
- **THEN** the upper layer is empty, the overlay mounts cleanly over the
  lower image, and the merged store is functional for new installs

### Requirement: Store-database coherence across an OTA swap is observable

When an OTA slot swap replaces the lower store while the upper layer and its database entries persist, upper-layer paths whose references existed only in the old lower MUST fail deterministically with a missing interpreter or library. Standard nix tooling MUST detect every validity record whose files are absent from the merged view, including stale old-lower records left by the additive swap merge.

#### Scenario: Upper path referencing an old-lower-only path fails

- **WHEN** an upper-layer tool's closure references a store path that was valid only in the pre-update lower image, and the tool is executed after the swap
- **THEN** execution fails with a missing-file error (no partial or silent misbehaviour), and the missing reference is identifiable from the error

#### Scenario: Verification reports dangling database entries

- **WHEN** the store verification command runs after such a swap
- **THEN** paths registered as valid whose files are absent from the merged view are reported (and are not silently treated as healthy)

### Requirement: Upper lifecycle across OTA updates is configurable

The module MUST offer `upperOnUpdate = "wipe"` (default) or `"reconcile"`.
Lifecycle actions MUST run at cutover — the first boot into a slot whose
image version differs from the lifecycle marker — and MUST NOT run on the
update trigger. Rejected/absent updates and same-version persistent-upper
reboots leave the upper untouched. An absent marker records a baseline
without wiping existing installs. Other values MUST be rejected at evaluation
time.

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

### Requirement: Garbage collection stays coherent on the overlay store

Garbage collection on the overlay store MUST delete only upper-layer paths
and MUST never mutate the lower image; after GC deletes an upper copy of a
path that is also valid in the lower store, the merged view MUST remain
coherent without manual remounting (the module MUST configure the store's
remount hook).

#### Scenario: GC removes an unpinned upper path, lower stays intact

- **WHEN** an upper-only path is unpinned and garbage collection runs
- **THEN** the path's files are removed from the upper layer and its
  database entry is dropped, while paths of the running system's closure
  (lower) remain present and the system keeps operating

#### Scenario: GC of a deduplicated path does not require manual repair

- **WHEN** garbage collection deletes an upper-layer copy of a path that
  also exists in the lower store
- **THEN** the overlay is remounted (or otherwise reconciled) via the
  configured hook, the merged view serves the path from the lower store,
  and no "needs remounting" warning is left unhandled in the journal

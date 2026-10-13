# overlay-nix Specification

## Purpose

The writable Nix store overlay for A/B appliances (`services.nixtache.overlay-nix`):
restores ad-hoc nix usage on machines whose `/nix/store` is a read-only
squashFS/erofs image partition, defines the persistence semantics of the
writable upper layer, and owns what happens to that layer across OTA slot
updates (wipe or reconcile).

## Requirements

### Requirement: Full nix surface over a read-only store

With the overlay enabled on an A/B appliance, nix MUST be re-enabled and
usable through the standard system daemon: ad-hoc realize, run, shell,
build, profile install and garbage collection all operate on the merged
view, writes land in the configured upper layer, and the lower image
partition is never mutated.

#### Scenario: Install a package at runtime on an appliance

- **WHEN** a package is realized (or profile-installed) from a configured
  substituter on an appliance whose `/nix/store` is a read-only image
- **THEN** the package's store paths land under the configured upper layer,
  the binary runs through the merged `/nix/store`, and the lower layer's
  content is byte-identical to the image

#### Scenario: The overlay is mounted before the daemon serves requests

- **WHEN** the appliance boots
- **THEN** the OverlayFS at `/nix/store` (lower = image partition, upper =
  configured upper layer) is active before the nix daemon serves any
  request, so every nix command observes the merged view

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

When an OTA slot swap replaces the lower store while the upper layer (and
its database entries) persist, upper-layer paths whose references existed
only in the old lower MUST fail deterministically (missing interpreter or
library — a hard execution error), and standard nix tooling MUST be able to
report the incoherence: a store-database entry whose files are absent from
the merged view is detected by the store verification command.

#### Scenario: Upper path referencing an old-lower-only path fails

- **WHEN** an upper-layer tool's closure references a store path that was
  valid only in the pre-update lower image, and the tool is executed after
  the swap
- **THEN** execution fails with a missing-file error (no partial or silent
  misbehaviour), and the missing reference is identifiable from the error

#### Scenario: Verification reports dangling database entries

- **WHEN** the store verification command runs after such a swap
- **THEN** paths registered as valid whose files are absent from the merged
  view are reported (and are not silently treated as healthy)

### Requirement: Upper lifecycle across OTA updates is configurable

The module MUST offer an explicit lifecycle policy for the upper layer
across OTA updates (option `upperOnUpdate`, working name): `"none"` (the
default — no lifecycle action, preserving current behaviour), `"wipe"`, and
`"reconcile"`.

#### Scenario: Default policy preserves current behaviour

- **WHEN** the option is not set and an OTA swap happens
- **THEN** no lifecycle action runs: upper-layer content and database
  entries are carried across the swap unchanged (the coherence hazard above
  remains the operator's concern)

#### Scenario: Wipe clears the upper layer at update cutover

- **WHEN** `upperOnUpdate = "wipe"` and an OTA update is triggered (CI
  trigger, idle-gated apply, or auto-update poll)
- **THEN** the upper layer and its database entries are cleared before the
  inactive slot is written, and after the swap the overlay remounts over
  the new lower with a functional merged store (new lower paths visible,
  nix usable, no stale upper content)

#### Scenario: Reconcile heals dangling references from the substituter

- **WHEN** `upperOnUpdate = "reconcile"`, the machine has rebooted into a
  new lower image, and an upper-layer tool's closure references paths
  missing from the merged view that the configured substituter can provide
- **THEN** a post-boot reconcile pass invalidates database entries whose
  files are gone, re-fetches only the missing referenced paths, and the
  previously broken upper-layer tool runs again — without reinstalling the
  whole upper layer

#### Scenario: Reconcile degrades safely without the substituter

- **WHEN** `upperOnUpdate = "reconcile"` and a dangling reference cannot be
  re-fetched (substituter unreachable or lacks the path)
- **THEN** the reconcile unit completes the boot sequence unaffected and
  reports the unrepaired paths (failing status with a journal record naming
  them) rather than blocking boot or deleting unrelated upper content

#### Scenario: Recorded installables are replayed after the swap

- **WHEN** `upperOnUpdate = "reconcile"` and profile installables were
  recorded before the update whose entire closure was invalidated by the
  swap
- **THEN** the reconcile pass re-installs the recorded installables after
  the repair step, so the recorded user-facing tools are runnable again

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

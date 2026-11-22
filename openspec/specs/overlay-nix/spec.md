# overlay-nix Specification

## Purpose

The writable Nix store overlay for A/B appliances (`services.nixtache.overlay-nix`):
restores ad-hoc nix usage on machines whose `/nix/store` is a read-only
squashFS/erofs image partition, defines the persistence semantics of the
writable upper layer, and owns what happens to that layer across OTA slot
updates (wipe or reconcile).

## Requirements

### Requirement: Full Nix surface over an input-addressed read-only store

With the overlay enabled on an A/B appliance, Nix MUST be usable through the standard system daemon: ad-hoc realize, run, shell, build, profile install and garbage collection all operate on the merged view. Writes for paths not already valid in the lower store MUST land in the configured upper layer without mutating the lower image, and runtime evaluation MUST work over input-addressed lower closures without requiring `ca-derivations`.

#### Scenario: Install a package at runtime on an appliance

- **WHEN** a package is realized (or profile-installed) from a configured substituter on an appliance whose `/nix/store` is a read-only image
- **THEN** the package's store paths not already valid in the lower store land under the configured upper layer, the binary runs through the merged `/nix/store`, and the lower layer's content is byte-identical to the image

#### Scenario: Runtime evaluation works over the input-addressed closure

- **WHEN** a profile install evaluates nixpkgs on an appliance whose lower closure is input-addressed and CA derivation support is disabled
- **THEN** the evaluation and install complete against the merged view, and paths already valid in the lower store retain their input-addressed identities

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

When a target upper chain is cloned for a new lower, its database and files MUST be checked together before the chain becomes ready. Missing files and stale validity records MUST be detectable and repairable in the target copy without invalidating or rewriting the active upper chain.

#### Scenario: Upper path referencing an old-lower-only path fails

- **WHEN** an unready target clone contains a tool whose closure references a store path absent from both the new lower and target upper
- **THEN** that tool fails deterministically inside the target preparation view, while the active upper and its working tools remain unaffected

#### Scenario: Verification reports dangling database entries

- **WHEN** store verification runs against such a cloned target store
- **THEN** paths registered as valid whose files are absent from the target merged view are reported, and the active upper database is not invalidated

#### Scenario: Verification checks reference closure metadata

- **WHEN** a target database retains valid-path records and upper files but its reference records no longer describe the complete closure
- **THEN** preparation repairs the reference metadata or rejects the target, and never marks a file-only or validity-only check as coherent

#### Scenario: An unready target is not treated as coherent

- **WHEN** target verification or repair leaves validity records whose files are absent from the target merged view
- **THEN** the target metaslot remains unready and is not presented to upper-dependent services as a prepared store

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

### Requirement: Slot-scoped upper lifecycle across OTA updates is configurable

The module MUST retain `upperOnUpdate = "wipe"` (default) or `"reconcile"`; other values MUST fail evaluation. Each physical slot MUST have independent persistent upper/state. Installation prepares only the inactive target. Boot recovery MAY prepare a bootloader-selected target under the same target-only rules; neither path MAY repair the preserved source in place.

#### Scenario: Default policy prepares an empty target upper

- **WHEN** the option is not set and a new lower image has been installed in the inactive slot
- **THEN** the default `"wipe"` policy clears only that slot's upper, work directory and upper-owned Nix state before loading the target lower records

#### Scenario: Wipe never clears the active upper for a slot swap

- **WHEN** `upperOnUpdate = "wipe"` and an update is prepared for the inactive slot
- **THEN** the active slot's upper files, database, gcroots and profiles remain intact regardless of whether the new boot later succeeds

#### Scenario: Reconcile clones and repairs the target upper

- **WHEN** `upperOnUpdate = "reconcile"` and a new lower image is installed in the inactive slot
- **THEN** the target receives a consistent copy of the active upper chain, missing closure paths are repaired against the new lower, and only the target copy is modified

#### Scenario: Reconcile preparation degrades without harming the active upper

- **WHEN** a required target closure path cannot be fetched or the target copy cannot be made coherent
- **THEN** preparation reports the unrepaired paths, leaves the target unready for retry, and preserves the active upper and its availability

#### Scenario: Recorded roots and profiles survive target preparation

- **WHEN** the active upper contains gcroots or per-user profiles whose closures require repair for the new lower
- **THEN** those roots and profile links are cloned into the target and their missing closure paths are repaired before the target becomes ready

#### Scenario: A rejected or absent update does not prepare an upper

- **WHEN** an update is rejected, tampered or interrupted before installation completes, or a no-op has no incomplete upper preparation from an earlier installation
- **THEN** neither slot's upper lifecycle action runs and the active upper remains exactly as it was

#### Scenario: A plain reboot keeps the selected persistent upper

- **WHEN** the machine reboots the same physical slot without installing another image
- **THEN** that slot's persistent upper files and Nix state remain selected and no wipe or clone-repair cycle occurs

#### Scenario: Rollback selects the preserved upper without reversing the policy

- **WHEN** the machine returns to the previous slot after a failed or manually reversed cutover
- **THEN** the previous slot's upper and Nix state are selected as preserved, with no wipe or reconcile merely because the running image version changed

#### Scenario: Slot reuse derives from the current active upper

- **WHEN** a later update reuses a physical slot whose old upper metaslot still exists
- **THEN** wipe discards only that target metaslot, while reconcile replaces the target from a fresh clone of the then-current active metaslot before repair

#### Scenario: Tmpfs upper reboots without stale validity records

- **WHEN** an upper resides on tmpfs and the machine reboots
- **THEN** that ephemeral layer and every dependent upper layer are reset before the current lower records load, and no persistent upper metaslot is cloned or retained for the ephemeral chain

#### Scenario: Ephemeral preparation creates no persistent upper copy

- **WHEN** an installed update is prepared while any node in a chain has a tmpfs upper
- **THEN** preparation succeeds without creating persistent upper or upper-state copies for that ephemeral chain, while persistent sibling branches retain their independent prepared state

#### Scenario: Storage-mode transitions follow the target declaration

- **WHEN** a target declaration changes a node or ancestor between tmpfs and persistent storage
- **THEN** preparation uses the target descriptor rather than the source mount table, publishes materialized state for a persistent target, excludes all ephemeral descendants for a tmpfs target, and never reuses a stale generation for the new storage identity

### Requirement: Upper-tree preparation is parent-first and atomic

A target metaslot MAY contain sibling or nested `local-overlay` uppers. Preparation MUST validate the graph and verify every node parent-before-child in a private target view. Each child MUST consume its prepared parent's frozen lower files and metadata, never its mutable runtime continuation. Every node's roots, profiles and cross-layer closure metadata MUST validate before the complete tree becomes ready.

#### Scenario: Sibling uppers reconcile independently over one parent

- **WHEN** two sibling target uppers have separate roots over the same target parent
- **THEN** the parent's frozen lower is repaired before either child, each sibling is verified against that stable frozen view, and subsequent repair writes in one sibling are absent from the other sibling, the parent's runtime continuation and the active tree

#### Scenario: An intermediate upper reconciles before its child

- **WHEN** an intermediate target node and its leaf both have roots, and the intermediate closure requires an object absent from the new lower
- **THEN** the missing object is repaired into the intermediate's target frozen-lower representation before the leaf is mounted or verified, and the active intermediate upper remains unchanged

#### Scenario: A middle-and-leaf shared dependency is repaired at the middle

- **WHEN** roots at both an intermediate node and its descendant require the same missing object and that object is repaired into the intermediate's target frozen lower
- **THEN** the descendant resolves it through that frozen lower without fetching a second copy into the descendant upper

#### Scenario: A leaf-only dependency stays in the leaf

- **WHEN** only a leaf root requires an object missing from its prepared parent view
- **THEN** the object and any required duplicated closure metadata are added only to the target leaf upper and state, not to its parent or the active tree

#### Scenario: Siblings requiring the same leaf-only object do not share repairs

- **WHEN** roots in two siblings require the same object that is absent from their prepared parent and was not repaired as part of the parent's roots
- **THEN** each sibling target is made coherent independently and neither sibling depends on the other's upper directory or upper database

#### Scenario: Child closure metadata is validated after parent repair

- **WHEN** a cloned child upper database contains duplicated ancestor metadata from the source tree and its target parent has since been repaired
- **THEN** the child's files and duplicated closure records are refreshed or validated against the prepared parent's frozen lower before readiness, rather than accepting a file-only check

#### Scenario: Child upper cannot impersonate parent-provided state

- **WHEN** a path expected from a prepared parent is removed from that parent and copied into the child's own upper after an earlier local check
- **THEN** final whole-tree validation rejects the target because the child must resolve parent-provided paths through the prepared parent root, not through its own upper

#### Scenario: Any node failure blocks the complete target tree

- **WHEN** verification or repair fails at an intermediate node, a leaf or either sibling
- **THEN** no branch of that generation is marked ready, upper consumers do not start from a partially prepared tree, and the active tree remains usable and unmodified

### Requirement: Upper selection follows the physical lower slot

The active upper metaslot MUST be selected from the physical store partition chosen by the bootloader, not solely from the image version. The selected upper, lower database and dependent upper layers MUST identify one coherent chain.

#### Scenario: Manual selection of an older slot selects its upper

- **WHEN** both physical slots have prepared metaslots and the operator boots the older slot
- **THEN** the older lower and its own upper chain are mounted without consulting only which image version is newest

#### Scenario: Same-version slot installations remain distinguishable

- **WHEN** two physical slots contain the same image version but have different prepared upper state
- **THEN** the physical slot identity still selects the upper chain belonging to the booted partition

### Requirement: Existing shared uppers migrate without loss

Upgrading a system with a shared persistent upper MUST preserve that upper as the currently active slot's initial metaslot. Migration MUST NOT wipe or reconcile it merely because slot-scoped metadata is absent.

#### Scenario: First boot after upgrade preserves the active upper

- **WHEN** an existing appliance boots the slot-scoped implementation with a shared upper and no per-slot metadata
- **THEN** its upper files and Nix state become the active slot's metaslot and previously installed tools remain available

#### Scenario: The other slot is prepared before use

- **WHEN** the inactive slot has no migrated metaslot
- **THEN** it is marked unready until a subsequent update prepares it from the active chain under the configured policy

#### Scenario: Failed migration preserves every legacy source

- **WHEN** moving or activating any legacy upper, database, root, profile or temporary-root component fails or is interrupted
- **THEN** the legacy files and metadata remain usable, prior selection mounts and links are restored, readiness is not exposed, and a later retry can complete without discarding the source

#### Scenario: Cross-filesystem migration remains lossless

- **WHEN** legacy upper-owned state and its recovery backup reside on different filesystems
- **THEN** migration uses a lossless same-filesystem backup or copy fallback, validates the migrated chain and selects it without deleting the only usable legacy state

### Requirement: Children consume immutable parent lowers

A logical node with children MUST expose immutable parent files and metadata as their lower. Its own runtime writes MUST use a separate writable continuation over that lower; the continuation and children MUST be siblings.

#### Scenario: Adding the first child splits the logical parent

- **WHEN** logical topology `a → b` gains child `c`
- **THEN** the target physical topology becomes `a → b(lower) → {b-runtime, c}`, with `b-runtime` continuing the parent's own writable view and `c` consuming only the frozen `b` lower

#### Scenario: Runtime continuation writes do not mutate a child lower

- **WHEN** the consumer associated with `b` writes new paths or metadata after `b-runtime` and `c` have started
- **THEN** those writes land only in `b-runtime`, while the lower files and database consumed by `c` remain unchanged and read-only

#### Scenario: Parent runtime changes cross into a child only at rebase

- **WHEN** new target preparation incorporates a parent's runtime continuation into a new frozen lower and the child is restarted into that generation
- **THEN** the child resolves the newly frozen parent paths and metadata coherently, without requiring or observing live lower mutation in its previous generation

### Requirement: Topology operations preserve state across generation transitions

Adding, reparenting or removing declared nodes MUST prepare a coherent target graph without mutating the active tree. Under `reconcile`, unchanged branches MUST retain their state; under `wipe`, the same final graph MUST have clean writable upper/state. New and reparented subtrees MUST validate against their selected parents.

#### Scenario: Adding a sibling preserves the existing branch

- **WHEN** a new sibling is added below a parent that already has a runtime continuation and child under `reconcile`
- **THEN** the new branch is initialized without another parent split, existing sibling and continuation state is retained, and writes remain isolated between all siblings

#### Scenario: Adding a deeper descendant preserves its parent's logical view

- **WHEN** a descendant is added below an existing leaf at any depth under `reconcile`
- **THEN** only the required frozen-lower/runtime-continuation transformation and new branch are introduced, and the parent's own consumer retains its pre-transition store contents

#### Scenario: Reparenting revalidates the moved subtree

- **WHEN** a node and its descendants are moved to another parent in one target configuration under `reconcile`
- **THEN** the moved subtree retains its own upper state, duplicated lower metadata is refreshed against the new parent, and no generation prepared for the old parent is selected for the new graph

#### Scenario: Wipe applies clean state to the same operation

- **WHEN** any topology operation is prepared under `wipe`
- **THEN** the target derives the same final graph with clean writable upper/state while the active graph and its contents remain unchanged until cutover

#### Scenario: Removal never orphans descendants

- **WHEN** a declared node is removed while descendants remain
- **THEN** those descendants MUST be removed or explicitly reparented in the same operation; otherwise evaluation rejects the transition without changing the active graph

#### Scenario: Failed topology migration converges on retry

- **WHEN** preparation is interrupted while an intermediate frozen lower, runtime continuation or descendant is incomplete
- **THEN** the target remains unready, the active graph stays usable, and a retry completes or discards the incomplete target before validating the complete final graph

### Requirement: Runtime overlay paths are disjoint and stable

Module-managed upper, work and state paths MUST be component-wise disjoint within and across nodes. Node identities MUST be stable, unique path components; `.` and `..` MUST be rejected.

#### Scenario: Equal or nested managed paths are rejected

- **WHEN** upper, work or state paths within one node or across different nodes are equal or nested inside one another
- **THEN** evaluation rejects the topology before any selection or preparation action runs

#### Scenario: String-prefix paths remain valid

- **WHEN** managed paths share only a string prefix but none is a descendant path of another
- **THEN** evaluation accepts them as disjoint paths

#### Scenario: Path traversal identities are rejected

- **WHEN** a node identity is `.` or `..`
- **THEN** evaluation rejects the topology rather than deriving an on-disk layer path from that identity

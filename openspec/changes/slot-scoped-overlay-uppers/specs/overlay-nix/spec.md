# Spec Delta

## MODIFIED Requirements

### Requirement: Store-database coherence across an OTA swap is observable

When a target upper chain is cloned for a new lower, its database and files MUST be checked together before the chain becomes ready. Missing files and stale validity records MUST be detectable and repairable in the target copy without invalidating or rewriting the active upper chain.

#### Scenario: Upper path referencing an old-lower-only path fails

- **WHEN** an unready target clone contains a tool whose closure references a store path absent from both the new lower and target upper
- **THEN** that tool fails deterministically inside the target preparation view, while the active upper and its working tools remain unaffected

#### Scenario: Verification reports dangling database entries

- **WHEN** store verification runs against such a cloned target store
- **THEN** paths registered as valid whose files are absent from the target merged view are reported, and the active upper database is not invalidated

#### Scenario: An unready target is not treated as coherent

- **WHEN** target verification or repair leaves validity records whose files are absent from the target merged view
- **THEN** the target metaslot remains unready and is not presented to upper-dependent services as a prepared store

## REMOVED Requirements

### Requirement: Upper lifecycle across OTA updates is configurable

**Reason**: A single shared upper mutated at cutover cannot preserve the known-good upper when the new boot fails. Slot-scoped upper chains replace both the shared-state layout and the reverse-reconcile rollback model.

**Migration**: Keep `upperOnUpdate = "wipe" | "reconcile"` with the same default. Migrate the existing shared upper into the active slot without wiping it; prepare the inactive slot from the active chain on its next update.

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

## ADDED Requirements

### Requirement: Slot-scoped upper lifecycle across OTA updates is configurable

The module MUST retain `upperOnUpdate = "wipe"` (default) or `"reconcile"`. Each physical A/B slot MUST have independent persistent upper and Nix state. Policies MUST prepare only the inactive target: wipe resets it; reconcile clones the active upper and repairs that copy. Other values MUST fail evaluation.

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

- **WHEN** an update installs nothing because it is rejected, tampered, interrupted before installation completes, or has no newer version
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

### Requirement: Upper-tree preparation is parent-first and atomic

A target metaslot MAY contain sibling or nested `local-overlay` uppers. Preparation MUST validate the graph and verify every node parent-before-child in a private target view. Each child MUST consume its prepared parent's merged store and metadata. Every node's roots, profiles and cross-layer closure metadata MUST validate before the complete tree becomes ready.

#### Scenario: Sibling uppers reconcile independently over one parent

- **WHEN** two sibling target uppers have separate roots over the same target parent
- **THEN** the parent is repaired before either child, each sibling is verified against that stable parent view, and subsequent repair writes in one sibling are absent from the other sibling, the parent and the active tree

#### Scenario: An intermediate upper reconciles before its child

- **WHEN** an intermediate target node and its leaf both have roots, and the intermediate closure requires an object absent from the new lower
- **THEN** the missing object is repaired into the target intermediate upper before the leaf is mounted or verified, and the active intermediate upper remains unchanged

#### Scenario: A middle-and-leaf shared dependency is repaired at the middle

- **WHEN** roots at both an intermediate node and its descendant require the same missing object and that object is repaired as part of the intermediate root closure
- **THEN** the descendant resolves it through the prepared intermediate merged view without fetching a second copy into the descendant upper

#### Scenario: A leaf-only dependency stays in the leaf

- **WHEN** only a leaf root requires an object missing from its prepared parent view
- **THEN** the object and any required duplicated closure metadata are added only to the target leaf upper and state, not to its parent or the active tree

#### Scenario: Siblings requiring the same leaf-only object do not share repairs

- **WHEN** roots in two siblings require the same object that is absent from their prepared parent and was not repaired as part of the parent's roots
- **THEN** each sibling target is made coherent independently and neither sibling depends on the other's upper directory or upper database

#### Scenario: Child closure metadata is validated after parent repair

- **WHEN** a cloned child upper database contains duplicated ancestor metadata from the source tree and its target parent has since been repaired
- **THEN** the child's files and duplicated closure records are refreshed or validated against the prepared parent before readiness, rather than accepting a file-only check

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

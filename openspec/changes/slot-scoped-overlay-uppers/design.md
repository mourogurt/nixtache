# Design

## Context

See `proposal.md` for motivation and `specs/` for the observable contracts.

The current host overlay has one configured upper/work pair and one lifecycle marker. Its `/nix/var/nix` state survives independently of the lower slot and is cleared or repaired after a version-changing boot. The runner overlay adds a second OverlayFS upper under `store.path`, with its own upper state under the relocated `/nix`, while the host merged store and host database form its lower.

Nix's [`local-overlay` model](https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html) distinguishes the lower store's filesystem and metadata from the upper layer directory and upper SQLite database. A lower store may itself be a `local-overlay`, and multiple overlays may consume the same lower, so sibling and nested container topologies are valid compositions rather than special cases the module can prohibit. A mounted lower filesystem must not change beneath its consumers. An upper database may also duplicate ancestor metadata so its upper-object closures satisfy the local-store schema; copying only files or treating that database as exclusively node-local breaks those closures. The design therefore switches complete trees only across boots and prepares new trees in a private scratch mount topology.

## Goals / Non-Goals

**Goals:**

- Preserve a usable upper tree for every prepared physical slot without modifying it for a rollback.
- Make target preparation atomic from the perspective of every upper consumer and safe to interrupt at any node.
- Support single overlays, sibling overlays over one lower, nested overlays and their compositions, with distinct upper directories and state at every node.
- Keep manual sysupdate, deferred reboots and unrelated reboots inside the same whole-tree readiness contract.

**Non-Goals:**

- No container orchestration or automatic discovery of arbitrary mounts; module-managed layers supply stable node and parent descriptors so any supported sibling/nested composition can participate in one transaction.
- No per-slot copy of the runner's full `clone` store and no merging of distinct upper directories or databases into one store.
- No A/B partitioning or post-rollback sysupdate instance-selection redesign; that remains with `server-ab-migration-prep`.
- No snapshot semantics for application data outside the Nix upper/state chain.

## Decisions

### D1 — Physical slot identity is the partition UUID

Identify the mounted lower before mounting the host overlay, resolve its GPT `PARTUUID`, and use that stable identifier as the metaslot key. Image version, image ID and lower-dump checksum are metadata used to detect reinstallations; they are not the slot key.

This handles identical versions in two slots and partition relabelling during sysupdate. A newly recreated partition receives a new identity and cannot accidentally inherit an old metaslot. Unknown or ambiguous lower identity fails readiness rather than selecting an upper by guesswork.

Alternative considered: A/B names or image versions. A/B aliases are convenient for diagnostics but become ambiguous when labels change; versions do not identify a physical slot and can repeat.

### D2 — A metaslot bundles a rooted layer tree and both metadata roles

Use a per-slot directory with this logical shape:

```text
upper-slots/<partuuid>/
  metadata                  # slot, image, dump checksum, policy, topology, state
  host/
    lower-state/            # read-only records from this slot's dump
  layers/
    <stable-node-id>/
      upper/
      work/
      state/                # upper DB, roots, profiles, temproots
```

The host upper is the root node over the physical lower. Every other node names its parent; siblings name the same parent, while a nested container names the container whose merged store it consumes. Cycles, duplicate node identities and missing parents are invalid. A topology fingerprint covers all node identities and parent edges so a generation prepared for one graph cannot be selected for another.

The host lower database and every upper database have different roles. The host `local-overlay` reads the selected lower-state plus its writable upper state. Each descendant reads its parent's selected merged store and upper-owned metadata as its composite lower, then uses its own upper state. Nix may duplicate ancestor records inside a descendant upper database to keep closure metadata self-contained; preparation preserves and refreshes those records in the target instead of treating them as a shared database or stripping them as duplicates.

Stable runtime paths become selection points managed before consumers start: each configured upper/work path, each persistent upper-owned state subset and the host's `/nix/var/nix` paths. Early boot binds or symlinks these to one selected metaslot generation; daemon configuration does not need to contain a partition-specific path.

Work directories are recreated, never cloned. Daemon sockets and logs remain outside the persistent upper-owned subset. OverlayFS upper and work directories for each node stay on one filesystem.

Alternatives considered: version-keyed directories and one shared `/nix/var/nix` reintroduce same-version ambiguity and cross-slot database contamination. A fixed `host/runner` pair cannot represent valid sibling or deeper `local-overlay` compositions and was rejected as the internal model.

### D3 — Preparation traverses a private target tree parent-first

After sysupdate reports a completed installation, record the source active slot and resolve the changed inactive partition. Refuse preparation if the active partition changed or the target is ambiguous. Prepare the target through a dedicated service shared by CI-triggered, idle-gated and timer-driven updates:

1. Lock the target metaslot, validate its topology graph and create a staging directory beside it.
2. For `wipe`, create empty upper/state at every node and load the target lower dump.
3. For `reconcile`, snapshot or quiesce-and-clone the complete active tree into staging as one source generation, then load the target lower dump into the cloned target lower-state. Cloning every node before repair prevents a source child from observing different source-parent snapshots.
4. Mount the new lower and target root upper in a private mount namespace. Seed and verify the root target, including its own roots and profiles, repairing only the target root upper and state.
5. Visit every remaining node in topological order. Do not expose or mount a child's target view until its parent's target repair has completed and that parent view will remain unchanged while children consume it. Verify the current node's roots, profiles and closure against its prepared parent's merged store and metadata; fetch missing objects and duplicate required ancestor metadata only into the current target node.
6. Recheck every node, including intermediate nodes with roots and every leaf. Write readiness metadata only if all nodes validate, then atomically rename staging into the slot's prepared generation.

A dependency rooted at an intermediate node is repaired there once and is visible to its descendants. A dependency needed only by a leaf is repaired into that leaf. Siblings cannot repair through one another: each is verified against the same frozen prepared parent and owns its subsequent repairs. Failure at any intermediate, leaf or sibling leaves the entire generation unready, never a partially ready branch.

The active upper is never a repair target. Substituter accesses, database invalidation and GC-like deletions happen only in the target namespace and target state. No target parent is modified after its children begin verification.

For clone consistency, prefer same-filesystem snapshots of the complete tree when the storage supports them. The portable fallback quiesces all module-managed writers before copying, followed by full target verification; an unverifiable copy remains unready. Correctness never depends on a lucky copy of a live SQLite file because the active source remains untouched and the target is not exposed until validated.

Alternatives considered: replay only profiles into an empty target loses unprofiled roots and actual upper state. Verifying only leaves misses intermediate roots, while repairing a parent after cloning or mounting children can invalidate their duplicated lower metadata and violates the mounted-lower's immutability constraint. Repairing the active upper in place recreates the original rollback hazard.

### D4 — Readiness is a versioned generation, not a single mutable marker

A prepared record contains at least the physical slot ID, image ID/version, lower-dump checksum, policy, topology fingerprint, source slot and preparation generation. The topology fingerprint includes every stable node identity and parent edge. `ready` is written only after every node validates against the selected graph. Staging directories, interrupted generations and generations whose topology does not match the configured graph never count as ready.

A same-version lower rewrite invalidates readiness through the dump checksum. Reusing a slot creates a new generation from the then-current active tree; it never resurrects the target's old generation as the source.

When an update defers reboot to a window, record the source generation. Revalidate and, for reconcile, refresh the complete target tree from the active tree before the deferred reboot if any source node changed. Installation-time preparation therefore does not silently drop upper changes made at an intermediate, leaf or sibling while waiting for the window.

### D5 — Boot selects first and blesses only a ready chain

An early selection unit runs after required filesystems and before the lower-DB loader, host overlay, Nix daemon and runner container:

- resolve the booted lower's `PARTUUID`;
- select a prepared generation whose lower metadata matches the running image;
- if a newly installed candidate is unready, attempt target-only recovery using the preserved source metaslot;
- if recovery fails, leave upper consumers and boot-completion blocked on readiness;
- if an established prepared slot is selected, mount it without wipe, clone or reconcile.

Readiness orders module-managed upper consumers and `boot-complete.target` after successful selection. Thus an unrelated reboot that chooses an installed but unprepared UKI cannot bless it. Boot counting returns to the previous prepared slot, whose boot needs no lifecycle mutation.

Alternative considered: disarm the UKI whenever preparation fails. That may supplement operational cleanup but is insufficient as the sole mechanism because sysupdate and manual boot selection can bypass trigger-side bookkeeping.

### D6 — Sibling and nested overlays share one atomic readiness boundary

A runner lower is its parent's merged store, not independently the physical lower. The two primitive shapes are therefore a parent with two children and a parent-child-grandchild chain; larger supported trees are compositions of these shapes. Parent target repair completes before any child target repair, and siblings may proceed only after their common parent is stable. Their directories and databases stay separate; selection and readiness are shared by the whole tree.

For a relocated runner store, bind each selected or target parent's merged store and upper-owned metadata read-only under a dedicated lower root outside that runner's `/nix`. Both the runner OverlayFS `lowerdir` and its `local-overlay` lower store use this root. The custom daemon rebinds `/nix` to the runner's merged store, so a parent lower rooted there would be shadowed and the runner would read its own upper database instead of the selected parent's metadata.

Tests must exercise roots at intermediate nodes as well as leaves. In particular, a middle-and-leaf shared dependency proves that parent repair is visible to the child without a second repair, while a leaf-only dependency proves that repair does not leak into the parent. Two siblings rooting the same otherwise missing dependency prove both independence from the parent and isolation from each other. A final whole-tree verification catches stale duplicated metadata and cross-layer dangling references even when each node passed an earlier local check.

If any upper is tmpfs, its files disappear on reboot. Every descendant upper is then inherently ephemeral too: reset the entire descendant subtree's upper and upper-owned state at the same early-boot boundary instead of retaining dangling records. Persistent slot metaslots apply only below an entirely persistent ancestor chain.

Runner `clone` mode bypasses metaslot duplication and retains additive lower seeding.

### D7 — All reboot paths use the same preparation/readiness helper

`nixtache-ab-update`, the auto-update poll and deferred-reboot path invoke the shared target-preparation service after confirmed installation and before reboot. The stock reboot assessment receives readiness ordering so an alternate trigger cannot bypass it.

A direct manual `systemd-sysupdate` remains supported through the boot-time recovery path. No-op and rejected updates do not invoke preparation.

## Risks / Trade-offs

- [Two persistent uppers can double storage consumption] → Use CoW snapshots where available, document capacity requirements, and retain only the active and prepared target generations per physical slot.
- [Copying live upper files and SQLite can tear] → Prefer snapshots; otherwise quiesce module-managed writers and validate every target closure before readiness. Never sacrifice the active source to recover a bad copy.
- [A deferred reboot makes an installation-time clone stale] → Track the source generation and refresh the target before the deferred cutover when needed.
- [Dynamic upper paths can race early-boot consumers] → Centralize selection in one unit and pin strict `requires`/`after` relationships for the lower loader, mount units, daemons, runner container and boot-completion.
- [Custom upper-hosted services may start before readiness unless correctly wired] → Provide a stable readiness target for consumers and document that upper-hosted critical services must require and follow it as well as remain in `criticalUnits`.
- [Nested overlays inherit lower-mutation restrictions] → Replace lower trees only across reboots, finish each target parent before mounting target children and use private scratch mounts; never rewrite a mounted active lower or a target parent already consumed by a child.
- [Duplicated ancestor records in child upper databases become stale after cloning] → Refresh closure metadata separately in each target child and perform a final whole-tree closure check instead of assuming valid files imply valid metadata.
- [One repaired sibling can expose a partially usable but incoherent tree] → Publish no branch independently; one failed node keeps the complete generation unready and retry touches only that target generation.
- [Migration mistakes can strand the only existing upper] → Preserve the legacy source until the active migrated metaslot validates, retain compatibility selection paths, and make migration idempotent.

## Migration Plan

1. On the first boot of the new implementation, detect the physical active lower before any overlay mount and locate the legacy shared upper and Nix state.
2. Copy or snapshot them into that slot's initial metaslot, retaining the legacy source as a recovery backup. Split the existing database into the required lower/upper metadata roles and validate the migrated chain.
3. Atomically point the legacy-compatible runtime paths at the migrated metaslot, then start consumers. Mark the other physical slot unready; do not clone into it speculatively.
4. The next update prepares the other slot according to policy. Once the migrated active chain and one subsequent update/rollback cycle validate, an operator may remove the legacy backup.
5. If migration fails, leave the legacy paths and backup untouched and keep the new chain unready. Rolling back to the previous module continues to use the preserved shared upper.

## Open Questions

(none — storage-backend optimizations and exact unit names do not change the contracts or task breakdown)

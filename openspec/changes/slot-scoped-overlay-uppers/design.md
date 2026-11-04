# Design

## Context

See `proposal.md` for motivation and `specs/` for the observable contracts.

The current host overlay has one configured upper/work pair and one lifecycle marker. Its `/nix/var/nix` state survives independently of the lower slot and is cleared or repaired after a version-changing boot. The runner overlay adds another OverlayFS upper with its own state while consuming the host merged store and database as its lower.

Nix's [`local-overlay` model](https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html) separates lower files and metadata from the upper layer and upper SQLite database. A lower store may grow logically, but Linux OverlayFS additionally requires a directory used as a lower not to change beneath its consumers. Nix's `read-only=true` SQLite mode is `immutable`, so it is not a safe live view of a database that another process continues to modify. A writable parent-daemon socket would provide fresh metadata but would not provide a read-only security boundary. The design therefore gives every child an immutable parent lower and moves the parent's own writes into a separate runtime continuation.

The logical consumer graph and the physical storage graph are different concerns. Users evolve runner declarations; the module derives frozen lowers, runtime continuations, lower roots and per-slot state. Every transition still crosses a private target-preparation and boot-selection boundary; no active mounted tree is rewired in place.

## Goals / Non-Goals

**Goals:**

- Preserve a usable upper tree for every prepared physical slot without modifying it for a rollback.
- Derive the internal overlay graph from production runner declarations rather than a parallel consumer-facing `layers` list.
- Support addition, reparenting and removal in breadth and depth while retaining unaffected state under `reconcile` and restoring one coherent final graph under either policy.
- Give every child immutable parent files and metadata, with an explicit generation-based rebase for parent runtime changes.
- Make target preparation atomic from the perspective of every upper consumer and safe to interrupt at any node or publication boundary.
- Keep manual sysupdate, deferred reboots, repeated installations and unrelated reboots inside the same whole-tree readiness contract.

**Non-Goals:**

- No live mutation or reparenting of an active mounted tree, no live direct reads of a changing parent SQLite database, and no write-capable parent-daemon socket exposed as a purported read-only lower.
- No automatic discovery of arbitrary mounts or consumer-managed low-level layer descriptors. Module-managed runner declarations are the source of non-host overlay nodes.
- No per-slot copy of the runner's full `clone` store and no merging of distinct writable upper directories or databases into one store.
- No A/B partitioning or post-rollback sysupdate instance-selection redesign; that remains with `server-ab-migration-prep`.
- No snapshot semantics for application data outside the Nix upper/state chain.
- No claim of formal verification for arbitrary graphs or unbounded operation sequences. The future path in the verification section is documentation only, not a proof obligation for this change.

## Decisions

### D1 — Physical slot identity is the partition UUID

Identify the mounted lower before mounting the host overlay, resolve its GPT `PARTUUID`, and use that stable identifier as the metaslot key. Image version, image ID and lower-dump checksum are metadata used to detect reinstallations; they are not the slot key. Discovery may use the standard `findmnt` PARTUUID interface rather than duplicating device and symlink resolution.

This handles identical versions in two slots and partition relabelling during sysupdate. A recreated partition receives a new identity and cannot inherit an old metaslot. Unknown or ambiguous lower identity fails readiness rather than selecting an upper by guesswork.

Alternative considered: A/B names or image versions become ambiguous after relabelling or same-version installations.

### D2 — Runner declarations are the only topology source

A named collection of runner-container declarations carries each container's store settings and one logical `parent` reference; `null` selects the host store. The attribute name is the stable logical node identity and the default container/unit identity. The existing singleton runner configuration maps to one declaration for compatibility. A rename is remove-plus-add unless an explicit future state-migration operation says otherwise.

The logical graph contains the host and eligible runner stores. A runner using clone mode or its native `/nix` store does not acquire an overlay node and cannot parent an overlay child. From this graph the module derives:

- physical frozen-lower and runtime-continuation nodes;
- stable internal identities and parent edges;
- upper, work, upper-owned state and dedicated lower-root paths;
- parent-first preparation order, runtime mount wiring and readiness dependencies.

There is no independent public `layers` list to drift from container declarations. Assertions reject missing parents, cycles, unsafe identities including `.` and `..`, incompatible parent store modes, and equal or nested upper/work/state paths within or across nodes. Path comparison uses path components, so names sharing only a string prefix remain valid. OverlayFS upper and work directories for one writable node stay on one filesystem.

Alternative considered: retaining a low-level layer API would let tests construct trees the production runner cannot express and would duplicate ownership of identities, paths and parent wiring.

### D3 — A logical parent is a frozen lower plus a runtime continuation

A leaf's writable upper serves its own consumer. When a leaf gains its first child, target preparation promotes its current logical store view to an immutable lower containing both files and complete Nix metadata. It then creates two sibling branches over that lower:

```text
logical:   a → b → c
physical:  a → b(lower) → { b-runtime, c }
```

`b-runtime` is the writable continuation for the consumer formerly associated with leaf `b`; its merged view contains frozen `b` plus its own new writes. Child `c` consumes frozen `b` only. Adding another child below `b` adds another sibling and does not repeat the promotion. The host follows the same rule when it first acquires an overlay child.

At each new prepared generation, reconciliation freezes the parent's latest logical view, including its previous runtime continuation, into the new parent lower. The new runtime continuation starts empty because the previous runtime contents are already represented in that lower. Existing children retain their own uppers according to policy and are repaired against the new frozen parent. An implementation may flatten or internally layer the frozen representation, but that representation is immutable for the whole selected runtime lifetime.

Consequences:

- `b-runtime` writes never appear in `c` during the current generation;
- `c` never opens a changing SQLite database and never receives a writable parent-daemon socket;
- a child sees later parent runtime writes only after a new generation freezes them and the child restarts into that generation;
- removing a child does not merge a runtime continuation back into its lower on a live system; retaining the split representation is valid even when only the continuation remains.

Alternative considered: live read-only binds of the parent's current upper state still mix a changing filesystem with immutable SQLite semantics. A metadata-only copy also diverges from the visible files and requires undocumented invalidation.

### D4 — Topology changes are generation operations

The target NixOS configuration emits a topology descriptor derived from its runner declarations. The completed lower installation carries that descriptor with its other target metadata. Preparation running on the source system MUST read the target descriptor rather than assuming that the source graph is also the target graph. A missing, ambiguous or inconsistent descriptor blocks preparation and reboot.

Preparation compares source and target logical graphs and applies the operations below. Their structural result is identical under both policies. State retention describes `reconcile`; `wipe` derives the same final graph with empty writable uppers/state. Neither policy mutates the active source.

- **Add in breadth:** initialize a new sibling branch; preserve existing siblings and the parent's continuation.
- **Add in depth:** perform the D3 promotion when this is the parent's first child, then initialize the new descendant.
- **Reparent:** preserve the moved node's own upper state where the configured policy permits, repair it against the new frozen parent, and revalidate its complete descendant subtree. A parent cannot move below itself.
- **Remove:** remove runtime wiring and the target branch. Descendants must be removed or explicitly reparented in the same target declaration; silent adoption is invalid. Old generations retain the old branch for rollback until normal retention discards them.
- **Change storage settings:** retain the logical identity only when an explicit migration can preserve path and state safety; otherwise treat the change as remove-plus-add. Clone/overlay mode transitions follow the same rule and never copy a clone store into a metaslot.

Each physical node records a lineage fingerprint containing its logical identity, storage role and frozen-parent lineage. Under `reconcile`, an unchanged branch can be reused when its lineage and lower checksum still match. A separate whole-generation fingerprint covers the final logical and physical graph. Thus a graph operation does not invalidate unrelated branch state, but an old whole generation is never selected for a different final graph.

Intermediate states may be invalid while a promotion, reparent or repair is in progress. They remain private and unready. Only the completed final graph can publish.

### D5 — A metaslot stores generations and both metadata roles

Use a per-slot layout with bounded current generations:

```text
upper-slots/<partuuid>/
  current -> generations/<generation>
  generations/<generation>/
    metadata                  # slot, lower, policy, graph, lineage, source, state
    host/
      lower-state/            # read-only records from this slot's dump
    nodes/
      <physical-node-id>/
        upper/                # when the physical node is writable
        work/
        state/                # upper DB, roots, profiles, temproots
        frozen-lower/         # files and metadata when used as a child lower
```

The host lower database and every writable upper database have different roles. A frozen parent lower carries its files and all metadata needed by children. A child upper database may duplicate ancestor records so its upper-object closures satisfy the local-store schema; preparation refreshes and validates those records instead of stripping them or treating them as a shared writable database.

Stable runtime paths are selection points managed before consumers start. Early boot binds or symlinks upper/work paths, persistent upper-owned state and host `/nix/var/nix` subsets to one selected generation. Work directories are recreated, never cloned. Daemon sockets and logs remain outside the persistent upper-owned subset.

### D6 — Preparation constructs a private target graph parent-first

After sysupdate reports a completed installation, record the source active slot and resolve the changed inactive partition. Refuse preparation if the active partition changed, the target is ambiguous or the target descriptor does not match the installed lower. The shared service handles CI-triggered, idle-gated, timer-driven and boot-recovery preparation:

1. Acquire the target physical-slot lock. Installed and booted modes use the same lock and lock ordering. Validate the source and target graphs and create staging beside the target generations; never remove another process's staging directory.
2. For `wipe`, create empty writable uppers/state and construct the target frozen-lower/runtime-continuation shape. For `reconcile`, snapshot or quiesce-and-clone the complete source generation, including every runner continuation, then derive the target graph through D4. Reuse only branches whose lineage and lower identity match.
3. Load the target lower dump into cloned target lower-state. Construct each parent's frozen lower from its latest target logical view before mounting any of its children.
4. Mount the new lower and target root in a private mount namespace. Seed and verify the root, then visit physical nodes in topological order. A child's lower URL and filesystem root MUST resolve to its own prepared parent's frozen root, never the child's root or the parent's runtime continuation.
5. Verify each node's roots, profiles, valid-path records, reference closures and duplicated ancestor metadata. Fetch missing objects only into the current target. Recheck intermediate nodes and every leaf after all repairs so a child upper cannot impersonate missing parent-provided state.
6. Ephemeral nodes and all descendants below an ephemeral ancestor receive no persistent upper or upper-state copy. Persistent siblings continue through their own preparation and validation.
7. Publish only after the complete graph validates. Staging rename, `state=ready` and the `current` switch are separate recoverable publication boundaries. A retry either adopts a fully published ready generation matching the latest installation or discards an incomplete/orphaned one.
8. After publication, retain only the bounded set needed for active selection, prepared cutover and rollback. Superseded ready generations and abandoned staging do not grow without limit.

Cloning every source node before repair prevents children from observing different source-parent snapshots. Prefer same-filesystem CoW snapshots; otherwise quiesce every module-managed writer, including all derived runner containers, before copying. The active source is never a repair target. No target parent is modified after its children begin verification.

### D7 — Readiness always describes the latest installation and final graph

A prepared record contains the physical slot ID, image ID/version, lower-dump checksum, policy, logical and physical topology fingerprints, per-node lineage, source slot/generation and preparation generation. `ready` is written only after every node validates against the final graph.

A same-version lower rewrite invalidates readiness through the dump checksum. Reusing a slot creates a generation from the then-current active tree rather than reviving stale target contents. Preparation remains rerunnable after earlier success: installing v2 and then v3 without an intervening reboot MUST publish and select a ready v3 generation, not the earlier v2 result.

When an update defers reboot, record the source generation. Revalidate the target before deferred cutover if any source node changed. Under `reconcile`, refresh the complete target and freeze the latest parent runtime continuations so children receive a coherent rebase rather than silently losing parent changes or reading a live lower. Under `wipe`, repeat validation against the latest installed lower while keeping target writable upper/state clean.

No-op and rejected updates do not invoke preparation. An entirely ephemeral chain has a successful no-persistent-metaslot preparation result so managed OTA and deferred reboot can proceed without inventing a selected persistent slot.

### D8 — Boot selects first and blesses only a ready chain

An early selection unit runs after required filesystems and before the lower-DB loader, overlays, Nix daemons and runner containers:

- resolve the booted lower's `PARTUUID`;
- select a prepared generation whose lower and final graph metadata match the running configuration;
- if a newly installed candidate is unready, attempt target-only recovery under the D6 lock using the preserved source metaslot;
- if recovery fails, leave upper consumers and boot completion blocked on readiness;
- if an established prepared slot is selected, mount it without wipe, clone or reconcile.

Readiness orders every derived upper consumer and `boot-complete.target` after successful selection. Boot counting returns to the previous prepared slot, whose lower, logical graph, frozen lowers and runtime continuations need no lifecycle mutation. A manual older-slot boot and forced boots of both same-version slots follow the same physical identity rule.

### D9 — Legacy and layout migration are transactional

Migration records a move only after that move succeeds. Place recovery backups on the source filesystem, or use a verified copy fallback when a rename would cross filesystems. Rollback must not remove a legacy source before the backup's existence and usability are confirmed. The same transaction covers upper/work links and each `db`, `gcroots`, `profiles` and `temproots` activation; interruption between components restores the previous mounts and links and does not expose readiness.

On first boot with legacy shared state, migrate that state into the active slot, validate the complete chain and retain a recovery backup. Mark the other slot unready until its first target preparation. Migration and retry are idempotent. Failure leaves the previous module's legacy paths usable.

### D10 — Runner wiring consumes frozen lowers outside relocated `/nix`

For a relocated runner store, bind its selected parent's frozen merged files and metadata read-only under a dedicated lower root outside that runner's `/nix`. Both the runner OverlayFS `lowerdir` and its `local-overlay` lower store use this frozen root. The custom daemon rebinds `/nix` to the runner's merged store, so a parent lower rooted there would be shadowed and would read the runner's own upper database.

The runner associated with a parent logical node instead consumes its frozen lower plus its own runtime continuation. This is a different view from its children, which consume the frozen lower alone. No startup copy of parent DB/gcroots/profiles/temproots is used as a metadata-only substitute for either view.

Runner `clone` mode bypasses metaslot duplication and retains additive lower seeding.

### D11 — Module files separate ownership boundaries

Split `modules/overlay-nix/default.nix` by responsibility rather than accumulating independent script generators in one module:

- `topology.nix`: logical declarations, derived physical graph, validation, lineage and fingerprints;
- `preparation.nix`: locking, staging, cloning, repair, verification, publication and retention;
- `selection.nix`: physical-slot discovery, generation selection and runtime activation;
- `migration.nix`: legacy and layout moves, backups, activation rollback and idempotent retry;
- `systemd.nix`: units, readiness targets and consumer ordering;
- `default.nix`: public options, shared path constants and imports only.

Runner modules consume the derived graph through an explicit internal interface; they do not reconstruct parent edges or lower paths independently. This split is an implementation boundary and does not create another consumer-facing topology API.

### D12 — Verification uses production modules and operation oracles

Pure-eval tests derive graphs from real runner declarations and assert internal nodes, frozen-parent roots, path safety, lineage, systemd dependencies and accepted/rejected operations. KVM fixtures instantiate production runner and overlay modules. A synthetic storage fixture may remain a focused oracle for repair mechanics, but passing it is not evidence of runner-level sibling or nested support.

Operation-based tests start from a declared graph, apply add, reparent and remove operations at several widths and depths, and compare the resulting production configuration and final stores with the operation's contract. They do not bless one hard-coded composed tree as the only production topology. Generated valid sequences vary parent shape and root placement; invalid cycles, self-reparenting, orphaned removal and path collisions must fail without changing the active graph. Representative traces also exercise failure/retry and rollback.

The runner freshness scenario has two phases: a parent runtime write is absent from its running child, then a prepared rebase and child restart expose both the path and validity record from the new frozen lower. Other regression coverage includes parent-root tampering, corrupted reference metadata, both same-version slots, ephemeral managed OTA, repeated installation without reboot, migration move failures and cross-filesystem backup, activation/publication interruptions, concurrent preparation and bounded retention. The VM workflow inventory must exactly match the flake's VM outputs, and the full matrix must pass on the reviewed SHA.

### Future formal verification — non-goal

A future effort could build a pure reference state machine over logical/physical graphs, generations and readiness, then use Alloy for bounded graph-operation checks or PlusCal/TLA+ for crash, retry and publication interleavings. Property-based generators could compare operation histories against production NixOS evaluation and shrink failing traces before replaying them as KVM tests. A refinement mapping could relate evaluated graphs, systemd edges, journal markers, readiness metadata and store URLs to abstract states and actions.

Those methods would provide bounded or counterexample-based evidence unless paired with a separate mechanized refinement proof. This change requires D12's production operation tests, not a formal model, exhaustive proof, or verification of shell, systemd, Nix, SQLite and OverlayFS implementations. The testing guide documents this boundary and future path without presenting it as completed verification.

## Risks / Trade-offs

- [Frozen lowers and generations increase storage consumption] → Prefer CoW snapshots, flatten frozen representations where practical, document capacity requirements and enforce bounded retention.
- [Parent runtime changes are not immediately visible to children] → Make rebase-plus-restart the explicit API and document the isolation/freshness rule at the runner consumer boundary.
- [A target configuration can change independently of the source preparation code] → Install a derived target topology descriptor and reject missing or inconsistent descriptors instead of guessing.
- [Promotion and reparenting can leave complex intermediate states] → Keep them private and unready, derive them from operation semantics, and converge through retry rather than activating partial branches.
- [Copying live upper files and SQLite can tear] → Prefer snapshots; otherwise quiesce every derived writer and validate every target closure before readiness.
- [Dynamic upper paths can race early-boot consumers] → Centralize selection and pin strict readiness dependencies for every derived mount, daemon and container.
- [Nested overlays inherit lower-mutation restrictions] → Freeze parent lowers, replace trees only across boots, finish each target parent before mounting children and use private scratch mounts.
- [Duplicated ancestor records become stale after cloning or reparenting] → Refresh closure metadata in every target child and perform final whole-tree reference and parent-root checks.
- [Publication and migration interruptions can strand the only usable state] → Use per-slot locks, recoverable publication boundaries, successful-move journaling, same-filesystem backups and restoration of prior activation paths.
- [Operation-based tests are not exhaustive proof] → Generate varied traces and document the formal-verification non-goal rather than claiming coverage of every possible graph.

## Migration Plan

1. On the first boot of the new implementation, discover the active physical lower and migrate legacy shared upper/state under D9. Keep the legacy source and backup usable until the migrated active chain validates.
2. For each completed installation, read the target topology descriptor and derive add, reparent, remove or storage-change operations from the active and target logical graphs.
3. Prepare a private generation: freeze the required parent views, create runtime continuations and new branches, preserve unchanged state, repair moved or lower-dependent branches, and publish only the final graph.
4. Reboot into the selected generation. Start each parent's own consumer with its frozen lower plus runtime continuation, and each child with the frozen parent lower alone.
5. To expose later parent runtime writes to children, schedule another preparation/rebase and restart the children into that generation. Do not refresh their lower databases or mounts in place.
6. On failed health or manual rollback, select the previous lower and its complete previous graph without reverse repair. Removed nodes therefore remain available only in generations that still need them for rollback.
7. After the migrated active chain and an update/rollback cycle validate, an operator may remove the legacy recovery backup. Normal generation retention preserves only the active and prepared generations needed thereafter.

## Open Questions

(none — storage-backend optimizations and exact internal helper names do not change the contracts or task breakdown)

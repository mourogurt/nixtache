# Spec Delta

## MODIFIED Requirements

### Requirement: Overlay mode uses a local lower store on appliance hosts

In overlay mode on a nix-less host, the custom daemon MUST use a dedicated read-only local lower outside its relocated `/nix`. A slot-scoped lower MUST contain the selected parent's frozen files and metadata, never its mutable runtime continuation or a copied metadata-only snapshot.

#### Scenario: Overlay daemon serves a coherent merged view on an appliance

- **WHEN** the runner container runs in overlay mode on an appliance host
- **THEN** the overlay store opens the dedicated read-only local lower, lower paths resolve with their validity records, builds write to the upper layer, and no daemon self-connection loop occurs

#### Scenario: Selected parent metadata survives the runner /nix rebind

- **WHEN** a slot-scoped host or parent runner lower is selected and the child runner's custom daemon rebinds `/nix` to its merged relocated store
- **THEN** the child resolves lower paths through the frozen parent's store and metadata at the dedicated read-only root outside `/nix`, without treating its own upper database as the lower

#### Scenario: Parent runtime writes wait for a child rebase

- **WHEN** the parent's own runtime continuation gains a new rooted path while a child runner is running
- **THEN** the child lower remains unchanged until a later prepared generation incorporates that runtime state into a new frozen parent lower and restarts the child into it

#### Scenario: Rebased parent metadata is fresh after restart

- **WHEN** a new prepared generation freezes the parent's previous runtime continuation and the child runner starts against that generation
- **THEN** the child resolves both the parent files and their current validity records without a live SQLite read, a metadata-only copy or access to a write-capable parent daemon socket

## ADDED Requirements

### Requirement: Runner overlay state follows the host upper metaslot

In runner `overlay` mode on an A/B appliance, every runner upper directory and its upper-owned Nix state MUST belong to the same physical-slot metaslot as the host store beneath it. Preparation and rollback MUST switch the host and all runner layers as one coherent tree, regardless of whether runner containers are siblings or nested inside one another.

#### Scenario: Target preparation repairs the tree in order

- **WHEN** a target metaslot contains a host upper and one or more runner overlay nodes
- **THEN** the host layer is seeded and repaired against the new physical lower first, every other parent's frozen lower is prepared before its children, and each runner node is validated against its own prepared parent's frozen lower

#### Scenario: Rollback restores every runner and host upper

- **WHEN** a new slot fails boot health and the previous slot boots
- **THEN** each runner container sees the previous physical lower and its complete previous ancestor and upper chain together, and its earlier CI store remains usable without reverse reconciliation

#### Scenario: Runner changes do not leak into another slot or sibling

- **WHEN** CI builds or profile changes write to an active runner upper
- **THEN** those writes do not modify the inactive slot's upper tree, a sibling runner upper or any sibling upper database

#### Scenario: An ephemeral layer resets its complete descendant subtree

- **WHEN** any host or runner upper in the tree is ephemeral and the machine reboots
- **THEN** every descendant runner upper and its upper-owned state are also reset so no records survive for files lost from an ancestor upper

### Requirement: Runner declarations derive the internal overlay topology

Users MUST declare runner containers and store-parent relationships through runner options. The module MUST derive layer identities, parent edges, frozen lowers, runtime continuations, lower roots and managed paths internally, without a parallel consumer-facing `layers` list.

#### Scenario: Sibling declarations generate sibling layers

- **WHEN** two enabled runner containers name the host as their store parent
- **THEN** the module derives two independent overlay nodes over the same frozen host lower, including their upper/work/state paths and dedicated lower roots

#### Scenario: A nested declaration generates a frozen lower and continuation

- **WHEN** a runner container names another runner container as its store parent
- **THEN** the module derives the parent's immutable lower, a runtime continuation for the parent's own container and a child branch over that lower, rather than wiring the child to the mutable continuation

#### Scenario: Clone and native stores do not generate upper-metaslot nodes

- **WHEN** a runner uses clone mode or its native `/nix` store
- **THEN** no slot-scoped overlay node is generated for that runner, and an overlay child cannot select it as an overlay parent

#### Scenario: Invalid declarations fail before runtime changes

- **WHEN** a named parent is missing, parent edges form a cycle, identities are unsafe or derived managed paths collide
- **THEN** evaluation rejects the configuration before any container, mount or metaslot is changed

### Requirement: Runner topology changes are operation-based

Runner configurations MUST support addition, reparenting and removal at any breadth or depth without assuming a fixed production tree. Target preparation MUST use the target declarations; the active graph MUST remain unchanged until the complete new graph is ready. State retention follows `upperOnUpdate`: `reconcile` preserves eligible branches, while `wipe` creates clean target state.

#### Scenario: Add operations converge in breadth and depth

- **WHEN** a target configuration adds a sibling or a deeper descendant to an existing runner graph under `reconcile`
- **THEN** production runner wiring and internal layers are generated for the new graph, unchanged branches retain their state, and the final target passes the same parent-first and isolation checks as any other graph

#### Scenario: Wipe derives the same graph with clean state

- **WHEN** any runner topology operation is prepared under `wipe`
- **THEN** production runner wiring converges to the same final graph with clean writable upper/state while the active graph remains unchanged until cutover

#### Scenario: Reparent operations converge with their descendants

- **WHEN** a target configuration moves a runner and its subtree to another store parent
- **THEN** the moved runner and descendants are prepared against the new frozen parent, their previous duplicated lower metadata is not accepted as current, and the old active graph remains available until cutover

#### Scenario: Remove operations converge without implicit adoption

- **WHEN** a target configuration removes a runner leaf, or removes a subtree through explicit descendant removal or reparenting
- **THEN** its runtime wiring disappears from the target, remaining branches stay coherent, and no child is silently attached to the removed node's former parent

#### Scenario: Rollback restores the previous declared graph

- **WHEN** a target boot fails after a runner topology operation
- **THEN** rollback selects the previous lower, runner declarations, internal frozen lowers and runtime continuations as one preserved graph

### Requirement: Sibling and nested runner overlays compose into one metaslot

Runner overlay preparation MUST NOT assume a fixed host-to-single-runner cascade. Stable runner node identities and parent relationships MUST support multiple containers over one frozen host lower, containers nested over another runner's frozen lower, and compositions of those shapes. All runner nodes MUST share the metaslot's atomic readiness and rollback boundary while retaining independent uppers and state.

#### Scenario: Two runner containers share the host lower

- **WHEN** two runner containers are siblings over the frozen host lower and CI roots exist in the host and in both containers
- **THEN** target host frozen-lower repair completes before either runner repair, both containers validate their roots against that frozen view, and CI writes or missing-path repairs in one container never appear in the other

#### Scenario: A nested runner container consumes the middle runner store

- **WHEN** a second runner container runs inside a first runner container and the first runner's frozen lower is the second runner's lower
- **THEN** target preparation verifies the first runner's own roots before preparing the second, and the second resolves its parent-provided closure through the prepared first runner's frozen lower rather than the host, active tree or first runner's runtime continuation

#### Scenario: Middle and leaf CI roots exercise cross-layer closure repair

- **WHEN** the first and nested second runner both root a closure that needs repair, while the second also has an independent leaf-only root
- **THEN** the shared portion is available through the prepared middle frozen lower, the leaf-only portion is repaired only in the second runner, and their duplicated closure metadata is valid throughout the target tree

#### Scenario: A composed sibling-and-nested tree has one readiness result

- **WHEN** one host has two runner children and one of those runners has a nested runner child
- **THEN** every intermediate and leaf is prepared in topological order, a failure in any runner blocks the whole target metaslot, and rollback later selects the complete previous tree without reverse repair

### Requirement: Runner clone mode remains independent of upper metaslots

The full relocated store used in runner `clone` mode MUST retain its additive seeding behavior and MUST NOT be duplicated into per-slot upper metaslots as though it were an OverlayFS upper.

#### Scenario: Clone store survives a slot swap additively

- **WHEN** a runner in clone mode boots another prepared A/B slot
- **THEN** its existing relocated store is retained and the new lower closure is seeded additively without cloning the store into a second slot-owned copy

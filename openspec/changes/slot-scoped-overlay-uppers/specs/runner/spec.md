# Spec Delta

## MODIFIED Requirements

### Requirement: Overlay mode uses a local lower store on appliance hosts

In overlay mode on a nix-less host, the custom daemon's overlay store URL MUST use a dedicated read-only local lower rooted outside the runner's relocated `/nix`, not the daemon lower. The selected host or parent runner's merged store and lower metadata MUST be bound read-only beneath that root. A daemon lower would self-connect because no system daemon exists; a local lower rooted at `/nix` would be shadowed by the custom daemon's relocated-`/nix` bind and would read the runner's own upper database instead of its parent's lower metadata.

#### Scenario: Overlay daemon serves a coherent merged view on an appliance

- **WHEN** the runner container runs in overlay mode on an appliance host
- **THEN** the overlay store opens the dedicated read-only local lower, lower paths resolve with their validity records, builds write to the upper layer, and no daemon self-connection loop occurs

#### Scenario: Selected parent metadata survives the runner /nix rebind

- **WHEN** a slot-scoped host or parent runner upper is selected and the child runner's custom daemon rebinds `/nix` to its merged relocated store
- **THEN** the child resolves lower paths through the selected parent's store and metadata at the dedicated read-only root outside `/nix`, without treating its own upper database as the lower

## ADDED Requirements

### Requirement: Runner overlay state follows the host upper metaslot

In runner `overlay` mode on an A/B appliance, every runner upper directory and its upper-owned Nix state MUST belong to the same physical-slot metaslot as the host store beneath it. Preparation and rollback MUST switch the host and all runner layers as one coherent tree, regardless of whether runner containers are siblings or nested inside one another.

#### Scenario: Target preparation repairs the tree in order

- **WHEN** a target metaslot contains a host upper and one or more runner overlay nodes
- **THEN** the host layer is seeded and repaired against the new lower first, every other parent is prepared before its children, and each runner node is validated against its own prepared parent's merged store

#### Scenario: Rollback restores every runner and host upper

- **WHEN** a new slot fails boot health and the previous slot boots
- **THEN** each runner container sees the previous physical lower and its complete previous ancestor and upper chain together, and its earlier CI store remains usable without reverse reconciliation

#### Scenario: Runner changes do not leak into another slot or sibling

- **WHEN** CI builds or profile changes write to an active runner upper
- **THEN** those writes do not modify the inactive slot's upper tree, a sibling runner upper or any sibling upper database

#### Scenario: An ephemeral layer resets its complete descendant subtree

- **WHEN** any host or runner upper in the tree is ephemeral and the machine reboots
- **THEN** every descendant runner upper and its upper-owned state are also reset so no records survive for files lost from an ancestor upper

### Requirement: Sibling and nested runner overlays compose into one metaslot

Runner overlay preparation MUST NOT assume a fixed host-to-single-runner cascade. Stable runner node identities and parent relationships MUST support multiple containers over one host merged store, containers nested over another runner's merged store, and compositions of those shapes. All runner nodes MUST share the metaslot's atomic readiness and rollback boundary while retaining independent uppers and state.

#### Scenario: Two runner containers share the host lower

- **WHEN** two runner containers are siblings over the host merged store and CI roots exist in the host and in both containers
- **THEN** target host repair completes before either runner repair, both containers validate their roots against that host view, and CI writes or missing-path repairs in one container never appear in the other

#### Scenario: A nested runner container consumes the middle runner store

- **WHEN** a second runner container runs inside a first runner container and the first runner's merged store is the second runner's lower
- **THEN** target preparation verifies the first runner's own roots before preparing the second, and the second resolves its parent-provided closure through the prepared first runner rather than the host or active tree directly

#### Scenario: Middle and leaf CI roots exercise cross-layer closure repair

- **WHEN** the first and nested second runner both root a closure that needs repair, while the second also has an independent leaf-only root
- **THEN** the shared portion is available through the prepared middle layer, the leaf-only portion is repaired only in the second runner, and their duplicated closure metadata is valid throughout the target tree

#### Scenario: A composed sibling-and-nested tree has one readiness result

- **WHEN** one host has two runner children and one of those runners has a nested runner child
- **THEN** every intermediate and leaf is prepared in topological order, a failure in any runner blocks the whole target metaslot, and rollback later selects the complete previous tree without reverse repair

### Requirement: Runner clone mode remains independent of upper metaslots

The full relocated store used in runner `clone` mode MUST retain its additive seeding behavior and MUST NOT be duplicated into per-slot upper metaslots as though it were an OverlayFS upper.

#### Scenario: Clone store survives a slot swap additively

- **WHEN** a runner in clone mode boots another prepared A/B slot
- **THEN** its existing relocated store is retained and the new lower closure is seeded additively without cloning the store into a second slot-owned copy

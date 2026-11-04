# Proposal

## Why

The persistent Nix upper is currently shared by both A/B slots and is wiped or reconciled on the first boot of a different image, before boot health is known. A failed update can therefore destroy or rewrite the upper belonging to the known-good system, and rollback must repair the shared upper again instead of restoring the state that was previously healthy. This is unsafe when services involved in boot health run from the upper, including runner containers layered over the host overlay. The upper tree must also support runner topology changes without exposing a mutable parent store as a child's lower or requiring users to duplicate runner declarations as low-level layers.

## What Changes

- Give each physical A/B store slot its own persistent **upper metaslot**: a rooted tree of upper layers and their Nix state derived from module-managed consumers. Users declare runner containers and their store-parent relationships; stable layer identities, lower roots, upper/work/state paths and preparation order are internal results, not a parallel public `layers` configuration.
- Represent a logical parent with children as an immutable selected lower (files and database) plus a writable runtime continuation for the parent's own consumer. Children and the runtime continuation are siblings over that lower: adding `c` below `a → b` produces `a → b(lower) → {b′(runtime), c}`. Runtime writes to `b′` never mutate the lower consumed by `c`.
- Prepare only the inactive slot's metaslot after a lower image installs, using the target configuration's derived topology. `wipe` creates clean target state; `reconcile` snapshots or clones the active tree and repairs the target copy parent-before-child against the newly installed lower. Preparation never wipes or reconciles an active upper in place or mutates a mounted lower beneath its consumers.
- Support addition, reparenting and removal of runner nodes in breadth and depth as topology operations. Under `reconcile`, unchanged branches retain their state; under `wipe`, the same final graph receives clean target state. New or reparented subtrees are initialized and repaired, and removal never orphans children implicitly. Intermediate target states may be incomplete, but publication requires a coherent final tree; rollback retains the previous topology.
- Refresh a child's view of its parent's runtime writes only by preparing and selecting a new frozen-lower generation. No live SQLite snapshot or writable parent-daemon socket is used as a substitute for that generation boundary.
- Select the upper metaslot from the physical lower slot chosen by the bootloader. Returning to an older slot returns to its preserved upper tree and topology without a reverse wipe or reconcile, including after failed boot health checks and manual slot selection.
- Track preparation, logical and physical topology, and slot/version metadata explicitly. An incomplete target tree must not be presented as ready to upper-dependent services, and reusing a slot for a later update must derive its target state from the then-current active tree rather than reviving stale contents.
- Preserve ephemeral-upper semantics, including reset of every descendant below an ephemeral layer, and runner `clone` mode; the slot-scoped transaction applies to persistent OverlayFS uppers, not to RAM-only layers or the full additive runner store copy.
- Migrate an existing shared persistent upper into the currently active slot's metaslot without discarding it, and initialize the other slot according to the configured policy on its next update.
- Add reusable end-to-end coverage for failed boot health, rollback, interrupted preparation, publication, migration, concurrent preparation, retention and lower-dependent closures. Exercise sibling, nested and composed configurations through the production runner module, with operation-based add/reparent/remove transitions rather than treating one synthetic tree as the production topology.

## Capabilities

### New Capabilities

(none — the behavior belongs to the existing OTA, overlay and runner capabilities)

### Modified Capabilities

- `overlay-nix`: persistent upper persistence and lifecycle change from one shared, cutover-mutated upper to slot-scoped upper trees prepared out of place and selected with the lower slot; internal topology evolves through explicit operations with immutable parent lowers.
- `ab-ota`: a completed lower installation gains a target-upper preparation contract, and rollback restores the previous lower and its preserved upper tree without mutating it for the return trip.
- `runner`: declarative runner store-parent relationships generate sibling and nested overlay nodes, frozen parent lowers and runtime continuations, while clone-mode behavior remains unchanged.

## Impact

- `modules/overlay-nix/`: separate topology derivation, target preparation, boot selection, legacy/layout migration and systemd wiring; slot identity, per-slot state layout and lifecycle units.
- `modules/runner/`: declarative multi-container store-parent topology and generation of each container's lower/view wiring from the derived tree; no equivalent duplication for clone mode.
- `modules/ab-image/`, `modules/deploy-target/`, `modules/auto-update/`: coordination between completed lower installation, target topology metadata, upper preparation readiness and reboot/cutover behavior.
- `tests/`: pure-eval and KVM coverage through production runner and overlay modules for single, sibling, nested and composed configurations, add/reparent/remove operations, migration and publication faults, rollback, concurrent preparation and ephemeral reset.
- `doc/user_guide/{ota,overlay-nix}.md`, relevant runner and testing documentation, and `doc/GLOSSARY.md`: the upper-metaslot model, logical-versus-physical topology, runtime-continuation freshness rules, storage cost and recovery behavior; testing documentation also records formal verification as a non-goal and a possible future verification path.

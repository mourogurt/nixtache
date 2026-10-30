# Proposal

## Why

The persistent Nix upper is currently shared by both A/B slots and is wiped or reconciled on the first boot of a different image, before boot health is known. A failed update can therefore destroy or rewrite the upper belonging to the known-good system, and rollback must repair the shared upper again instead of restoring the state that was previously healthy. This is unsafe when services involved in boot health run from the upper, including a runner container layered over the host overlay.

## What Changes

- Give each physical A/B store slot its own persistent **upper metaslot**: the host upper and Nix state, plus the corresponding runner-overlay upper and Nix state when that layer is enabled. Layers retain their own stores and databases; the metaslot switches them as one chain rather than merging their directories.
- Prepare only the inactive slot's metaslot after a lower image installs. `wipe` creates clean target state; `reconcile` snapshots or clones the currently active upper chain and repairs the target copy against the newly installed lower. Preparation never wipes or reconciles the active upper in place.
- Select the upper metaslot from the physical lower slot chosen by the bootloader. Returning to an older slot returns to its preserved upper chain without a reverse wipe or reconcile, including after failed boot health checks and manual slot selection.
- Track preparation and slot/version metadata explicitly. An incomplete target chain must not be presented as ready to upper-dependent services, and reusing a slot for a later update must derive its target state from the then-current active chain rather than reviving stale contents.
- Preserve ephemeral-upper semantics and runner `clone` mode; the slot-scoped transaction applies to persistent OverlayFS uppers, not to RAM-only layers or the full additive runner store copy.
- Migrate an existing shared persistent upper into the currently active slot's metaslot without discarding it, and initialize the other slot according to the configured policy on its next update.
- Add end-to-end coverage for failed boot health, automatic and manual rollback, interrupted preparation, slot reuse, lower-dependent upper closures, and both the single-overlay and host-to-runner cascade topologies.

## Capabilities

### New Capabilities

(none — the behavior belongs to the existing OTA, overlay and runner capabilities)

### Modified Capabilities

- `overlay-nix`: persistent upper persistence and lifecycle change from one shared, cutover-mutated upper to slot-scoped upper chains prepared out of place and selected with the lower slot.
- `ab-ota`: a completed lower installation gains a target-upper preparation contract, and rollback restores the previous lower and its preserved upper without mutating that upper for the return trip.
- `runner`: the relocated overlay store participates in the host's slot-scoped upper chain, including its own upper database and state, while clone-mode behavior remains unchanged.

## Impact

- `modules/overlay-nix/`: slot identity, per-slot upper/state layout, target preparation, mount selection, migration and lifecycle units.
- `modules/ab-image/`, `modules/deploy-target/`, `modules/auto-update/`: coordination between completed lower installation, upper preparation readiness and reboot/cutover behavior.
- `modules/runner/store.nix`: selection and preparation of the runner overlay's upper and state as part of the host chain; no equivalent duplication for clone mode.
- `tests/`: pure-eval layout/ordering contracts and KVM scenarios covering host-only and cascaded overlays, failed boots, rollback, interrupted preparation and migration.
- `doc/user_guide/{ota,overlay-nix}.md`, relevant runner and testing documentation, and `doc/GLOSSARY.md`: the upper-metaslot model, persistence guarantees, storage cost and recovery behavior.

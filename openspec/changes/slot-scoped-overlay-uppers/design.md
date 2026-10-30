# Design

## Context

See `proposal.md` for motivation and `specs/` for the observable contracts.

The current host overlay has one configured upper/work pair and one lifecycle marker. Its `/nix/var/nix` state survives independently of the lower slot and is cleared or repaired after a version-changing boot. The runner overlay adds a second OverlayFS upper under `store.path`, with its own upper state under the relocated `/nix`, while the host merged store and host database form its lower.

Nix's `local-overlay` model distinguishes the lower store's filesystem and metadata from the upper layer directory and upper SQLite database. A lower store may itself be a local-overlay store, but a mounted lower filesystem must not be replaced or mutated underneath its consumers. The design therefore switches complete chains only across boots and prepares new chains in a private scratch mount topology.

## Goals / Non-Goals

**Goals:**

- Preserve a usable upper chain for every prepared physical slot without modifying it for a rollback.
- Make target preparation atomic from the perspective of upper consumers and safe to interrupt.
- Support the existing host-only and host-to-runner cascade shapes with their distinct databases and state.
- Keep manual sysupdate, deferred reboots and unrelated reboots inside the same readiness contract.

**Non-Goals:**

- No new arbitrary branch topology beyond the runner's existing single-overlay and cascade configurations.
- No per-slot copy of the runner's full `clone` store and no merging of distinct upper directories or databases into one store.
- No A/B partitioning or post-rollback sysupdate instance-selection redesign; that remains with `server-ab-migration-prep`.
- No snapshot semantics for application data outside the Nix upper/state chain.

## Decisions

### D1 — Physical slot identity is the partition UUID

Identify the mounted lower before mounting the host overlay, resolve its GPT `PARTUUID`, and use that stable identifier as the metaslot key. Image version, image ID and lower-dump checksum are metadata used to detect reinstallations; they are not the slot key.

This handles identical versions in two slots and partition relabelling during sysupdate. A newly recreated partition receives a new identity and cannot accidentally inherit an old metaslot. Unknown or ambiguous lower identity fails readiness rather than selecting an upper by guesswork.

Alternative considered: A/B names or image versions. A/B aliases are convenient for diagnostics but become ambiguous when labels change; versions do not identify a physical slot and can repeat.

### D2 — A metaslot bundles layers and both metadata roles

Use a per-slot directory with this logical shape:

```text
upper-slots/<partuuid>/
  metadata                  # slot, image, dump checksum, policy, state
  host/
    lower-state/            # read-only records from this slot's dump
    upper/                  # host OverlayFS upper
    work/
    state/                  # host upper DB, roots, profiles, temproots
  runner/                   # present only in runner overlay mode
    upper/
    work/
    state/                  # runner upper DB, roots, profiles, temproots
```

The host lower database and host upper database have different roles. The host `local-overlay` reads the selected lower-state plus its writable upper state. The runner reads the host's selected upper database as the metadata of its composite lower, then uses its own runner upper state. Do not load every record into one shared database.

Stable runtime paths become selection points managed before consumers start: the configured host upper/work paths, `/nix/var/nix`'s persistent upper-owned subset, and the runner's relocated upper/state paths. Early boot binds or symlinks these to the selected metaslot; daemon configuration does not need to contain a partition-specific path.

Work directories are recreated, never cloned. Daemon sockets and logs remain outside the persistent upper-owned subset. OverlayFS upper and work directories for each layer stay on one filesystem.

Alternative considered: version-keyed directories and one shared `/nix/var/nix`. These reintroduce same-version ambiguity and cross-slot database contamination.

### D3 — Preparation runs against a private target topology

After sysupdate reports a completed installation, record the source active slot and resolve the changed inactive partition. Refuse preparation if the active partition changed or the target is ambiguous. Prepare the target through a dedicated service shared by CI-triggered, idle-gated and timer-driven updates:

1. Lock the target metaslot and create a staging directory beside it.
2. For `wipe`, create empty upper/state layers and load the target lower dump.
3. For `reconcile`, snapshot or clone the current active metaslot into staging, then load the target lower dump into the cloned target lower-state.
4. Mount the new lower and target host upper in a private mount namespace. Seed and verify the host target, repairing only missing paths into the target host upper.
5. If runner overlay is enabled, expose the prepared host merged store and host upper database as the runner lower, then verify and repair the runner target into its own upper.
6. Verify readiness, write metadata, and atomically rename staging into the slot's prepared generation.

The active upper is never a repair target. Substituter accesses, database invalidation and GC-like deletions happen only in the target namespace and target state.

For clone consistency, prefer a same-filesystem snapshot when the storage supports it. The portable fallback is a quiesced copy of module-managed writers followed by full target verification; an unverifiable copy remains unready. Correctness never depends on a lucky copy of a live SQLite file because the active source remains untouched and the target is not exposed until validated.

Alternative considered: replay only profiles into an empty target. This loses unprofiled roots and the actual upper state. Repairing the active upper in place was also rejected because it recreates the original rollback hazard.

### D4 — Readiness is a versioned generation, not a single mutable marker

A prepared record contains at least the physical slot ID, image ID/version, lower-dump checksum, policy, topology, source slot and preparation generation. `ready` is written only after every layer validates. Staging directories and interrupted generations never count as ready.

A same-version lower rewrite invalidates readiness through the dump checksum. Reusing a slot creates a new generation from the then-current active chain; it never resurrects the target's old generation as the source.

When an update defers reboot to a window, record the source generation. Revalidate and, for reconcile, refresh the target from the active chain before the deferred reboot if the source changed. Installation-time preparation therefore does not silently drop upper changes made while waiting for the window.

### D5 — Boot selects first and blesses only a ready chain

An early selection unit runs after required filesystems and before the lower-DB loader, host overlay, Nix daemon and runner container:

- resolve the booted lower's `PARTUUID`;
- select a prepared generation whose lower metadata matches the running image;
- if a newly installed candidate is unready, attempt target-only recovery using the preserved source metaslot;
- if recovery fails, leave upper consumers and boot-completion blocked on readiness;
- if an established prepared slot is selected, mount it without wipe, clone or reconcile.

Readiness orders module-managed upper consumers and `boot-complete.target` after successful selection. Thus an unrelated reboot that chooses an installed but unprepared UKI cannot bless it. Boot counting returns to the previous prepared slot, whose boot needs no lifecycle mutation.

Alternative considered: disarm the UKI whenever preparation fails. That may supplement operational cleanup but is insufficient as the sole mechanism because sysupdate and manual boot selection can bypass trigger-side bookkeeping.

### D6 — The cascade is prepared host-first and reset at an ephemeral boundary

The runner lower is the host merged store, not independently the physical lower. Host target repair therefore completes before runner target repair. Their directories and databases stay separate; only selection and readiness are shared.

If the host upper is tmpfs, its files disappear on reboot. Any dependent runner upper is then inherently ephemeral too: reset its upper and upper-owned state at the same early-boot boundary instead of retaining dangling records. Persistent slot metaslots apply only below an entirely persistent chain.

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
- [Nested overlays inherit lower-mutation restrictions] → Replace lower chains only across reboots and use private scratch mounts for preparation; do not rewrite a mounted active lower chain.
- [Migration mistakes can strand the only existing upper] → Preserve the legacy source until the active migrated metaslot validates, retain compatibility selection paths, and make migration idempotent.

## Migration Plan

1. On the first boot of the new implementation, detect the physical active lower before any overlay mount and locate the legacy shared upper and Nix state.
2. Copy or snapshot them into that slot's initial metaslot, retaining the legacy source as a recovery backup. Split the existing database into the required lower/upper metadata roles and validate the migrated chain.
3. Atomically point the legacy-compatible runtime paths at the migrated metaslot, then start consumers. Mark the other physical slot unready; do not clone into it speculatively.
4. The next update prepares the other slot according to policy. Once the migrated active chain and one subsequent update/rollback cycle validate, an operator may remove the legacy backup.
5. If migration fails, leave the legacy paths and backup untouched and keep the new chain unready. Rolling back to the previous module continues to use the preserved shared upper.

## Open Questions

(none — storage-backend optimizations and exact unit names do not change the contracts or task breakdown)

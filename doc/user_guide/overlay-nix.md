# Overlay-nix (writable store on appliances)

`nixosModules.overlay-nix` gives an A/B appliance a working `nix` at runtime:
a writable OverlayFS layered over the read-only `/nix/store` image partition
via Nix's experimental `local-overlay-store`. Ad-hoc `nix shell`, `nix build`,
`nix profile install` and garbage collection work on a machine whose system
store is immutable — the lower (squashFS/erofs) image is never modified.
Canonical requirements:
[`openspec/specs/overlay-nix/spec.md`](../../openspec/specs/overlay-nix/spec.md).

```nix
imports = [ nixtache.nixosModules.overlay-nix ];

services.nixtache.overlay-nix = {
  enable = true;
  # upperDir = "/var/lib/nix-overlay/upper";   # persistent (default)
  # upperDir = "/tmp/nix-overlay/upper";       # RAM-only, wiped on reboot
  # upperOnUpdate = "wipe";                     # "wipe" (default) | "reconcile"
};
```

The appliance needs a substituter for anything it installs — typically the
runner host's binary cache:

```nix
nix.settings.substituters = [ "https://<runner-host>:5000" ];
nix.settings.trusted-public-keys = [ "<cache public key>" ];
```

## The shipped lower DB

Every nixtache appliance image ships its slot closure's store DB dump (see
[`ota.md`](ota.md)). With `overlay-nix`, the boot loader imports that dump
into the selected slot's read-only lower-state; Nix combines those records
with the separate writable upper database. This makes the lower a first-class
readable store:

- runtime installs are a **delta**: realizing a path whose closure is
  already valid in the lower downloads only the missing paths into the
  upper layer;
- an OTA swap replaces the lower, so upper paths whose dependencies lived
  only in the OLD lower genuinely break (missing interpreter/library) and
  their DB entries dangle — `upperOnUpdate` below exists exactly for this.

## Upper metaslots and generations

On an A/B appliance, the physical lower partition's GPT `PARTUUID` selects an
independent upper metaslot. `/etc/image-version` alone is not an identity: two
slots may contain the same version and different upper state. With the default
paths, a prepared upper generation has this shape:

```text
/var/lib/nix-overlay/upper-slots/<partuuid>/
  current -> generations/<generation>
  generations/<generation>/
    metadata                       # slot, lower, descriptor, graph and readiness
    overlay-topology.json          # target declaration descriptor
    plan.json                      # derived physical graph and operations
    host/{upper,work,state,lower-state}
    nodes/<physical-node>/{upper,work,state}
    layers/<logical-node> -> ../nodes/<consumer-physical-node>
```

The host's consumer state lives in `host`; non-host consumers have stable
`layers` aliases internally. These aliases and physical node names are module
implementation details, not consumer configuration. Upper, work and state
paths remain distinct by path component, and each writable node's upper and
work directories share one filesystem. `lower-state` contains the physical
slot's read-only dump records; each `state` contains upper-owned databases,
roots, profiles and temproots. Their roles are detailed in
[`lower-store-db.md`](../technical_details/lower-store-db.md).

A plain reboot selects the booted slot's current generation without a policy
run. Manual or automatic rollback likewise selects the older slot's preserved
lower-state, logical graph, frozen lowers, runtime continuations and writable
uppers together, without a reverse wipe, clone or reconcile.

| `upperDir` on | Plain reboot | Prepared OTA update | Rollback |
|---|---|---|---|
| persistent root FS | installs survive | target policy applies | previous slot's upper generation is selected unchanged |
| ZFS dataset (OpenZFS ≥ 2.2) | installs survive | same persistent-upper policy | same preservation rule |
| tmpfs | upper and all dependent upper state reset | no persistent metaslot is required for an entirely ephemeral host chain | the ephemeral chain resets again |

The upper layer may live on a ZFS dataset: OverlayFS needs `d_type` and
`renameat2` whiteout/exchange, provided by OpenZFS 2.2. The overlay mounts
after the pool import (`zfs-mount.service`). On older ZFS, keep the upper on
the ext4 root instead.

## Declared logical topology and physical frozen lowers

Runner overlay nodes come from the named runner declarations and logical
store-parent relationships shown in [`quickstart.md`](quickstart.md#store-modes-and-named-runner-containers).
The existing singleton declaration participates through the same derivation.
There is no consumer-facing low-level topology API to duplicate those
declarations. Clone and native stores create no overlay node and cannot parent
an overlay child.

Logical parentage is not the physical mount graph. When logical `b` gains its
first child `c`, preparation freezes `b`'s store view and gives its own
consumer a new writable continuation:

```text
logical:   a → b → c
physical:  a → b(lower) → { b-runtime, c }
```

`b-runtime` and `c` are siblings over immutable `b(lower)`. The parent's own
consumer uses frozen `b` plus `b-runtime`; `c` uses frozen `b` alone. Adding
another child adds another sibling without another split. Removing the last
child does not collapse a mounted split in place, and older generations retain
their physical shape for rollback.

Under `reconcile`, each generation rebase folds the parent's previous frozen
lower and latest runtime continuation into a new frozen lower with coherent
files and metadata. Its new runtime continuation starts empty because those
writes are already represented in the lower; eligible child uppers retain
their own state and are validated against the rebased parent. Under `wipe`,
the same physical shape receives clean writable state.

Consequently, parent runtime writes are absent from a running child. They
become visible only after a later preparation freezes them and the child
restarts into the selected generation. A child binds that frozen root and its
`db`, `gcroots`, `profiles` and `temproots` read-only outside its relocated
`/nix`; it does not read a changing SQLite database, receive a metadata-only
snapshot or use a write-capable parent daemon.

## Target preparation and topology operations

After sysupdate installs a lower in the inactive slot,
`nixtache-overlay-prepare.service` prepares only that target while the old
slot remains active. The stock reboot-assessment unit requires this service;
after a manual `systemd-sysupdate` installation, run it directly:

```bash
systemctl start nixtache-overlay-prepare.service
```

Every overlay-enabled image carries a target topology descriptor beside its
lower dump on the ESP. The signed descriptor records the schema, image
identity and version, lower-dump SHA-256 and target logical declarations.
Preparation validates it before staging, derives the physical graph from that
target descriptor rather than assuming the source and target graphs match,
and binds its checksum into readiness. A missing, malformed or inconsistent
descriptor blocks preparation and reboot.

Source and target declarations are compared as operations:

| Operation | Target result |
|---|---|
| add a sibling or deeper descendant | initialize the new branch; a first child performs the frozen-lower/runtime-continuation split |
| reparent a subtree | validate the moved node and all descendants against the new frozen parent; never move a node below itself |
| remove a leaf or subtree | omit that target branch; descendants must be removed or explicitly reparented, never silently adopted |
| change upper or state storage | derive a `storage-reset`: the same logical identity receives empty target state rather than an unsafe path move |
| change only work, lower-root or container wiring | rewire the same logical node and revalidate its generation |
| rename a declaration | remove the old identity and add the new one; it is not a state-preserving rename |

Both policies produce the same final logical and physical graph. `"wipe"`
(default) gives every writable node empty target upper/state and needs no
substituter for preparation. `"reconcile"` preserves eligible existing branch
state, gives added and storage-reset nodes empty state, and refreshes duplicated
ancestor metadata in moved or lower-dependent branches. Unrelated active
branches are not repair targets.

For reconcile, preparation quiesces module-managed Nix writers, clones the
complete active generation with `--reflink=auto`, resumes those writers, then
loads the target lower dump into target lower-state and repairs only the clone
in a private mount namespace. Parents are completed before children mount;
roots, per-user profiles, valid-path records and reference closures are checked
across the final tree. Missing objects are fetched only into the target.
Reusing a physical slot clones the then-current active generation, never the
target's stale prior contents.

`reconcile` requires a substituter that still serves old references.
`services.nixtache.runner.deploy.ab.retain` keeps five staged image versions by
default, but that is separate from NAR retention: configure the binary cache
and its store GC to retain closures needed for repair. Reflink-capable
filesystems share unchanged blocks; others need capacity for complete upper
and database copies. Copying is not an atomic storage snapshot, so stop custom
services that bypass the module-managed daemon and write directly to an upper
before running a manual reconcile.

## Readiness, interruption recovery and retention

Persistent preparation holds one per-target-slot lock for both installed-target
and boot-recovery modes. A concurrent process waits rather than removing
another process's staging tree. Work happens in staging beside the target
generations and remains unready while cloning, seeding or repair is incomplete.

Publication has three recoverable boundaries: staging becomes a generation,
its metadata changes from `state=unready` to `state=ready`, and the slot's
`current` link switches. Readiness is written only after the complete target
graph validates. Interruption at any boundary leaves the active generation
unchanged. After fixing the cause, rerun the oneshot:

```bash
systemctl restart nixtache-overlay-prepare.service
```

The retry adopts a fully published ready current generation matching the
requested target, or removes incomplete and superseded non-current attempts
and constructs a fresh one. Reconcile clones the latest active state again;
wipe constructs another clean target. Staging directories do not accumulate,
and repeated successful preparation retains at most the current and previous
ready generations in that target slot.

Preparation remains rerunnable after success. Consecutive installations without
an intermediate reboot therefore publish readiness for the latest installed
lower, not the earlier pending one. Metadata includes image version, lower dump
and descriptor checksums and whole-graph fingerprints. A same-version lower
rewrite with a changed dump also invalidates an earlier generation even though
its version string is unchanged. No-op or rejected updates do not invoke
preparation.

At boot, `nixtache-overlay-select.service` resolves the mounted lower's
`PARTUUID` and selects a ready generation whose lower, descriptor and graph
match the running image. An unprepared or rewritten lower triggers target-only
recovery before the lower loader, overlays, Nix daemons and runner consumers
start. Failed recovery leaves the chain unready and blocks
`boot-complete.target`, allowing boot counting to return to the preserved
previous slot.

There is no carry-over `"none"` policy value: it fails evaluation with the enum
naming the two valid values. An unset option uses `"wipe"`; to retain ad-hoc
installs across updates, choose `"reconcile"` with a suitably retained
substituter.

## Ephemeral chains and mixed-storage limitation

With a tmpfs host upper, selection resets the upper, work directory,
lower-state and upper-owned Nix state on **every** boot. Every descendant
overlay and its state resets as well, so no child retains records for files
lost from an ancestor upper. The loader then imports exactly the selected
slot's lower dump. Installed-target preparation validates the target descriptor
and returns a successful `ephemeral` result without creating a persistent
metaslot, allowing direct updates and immediate reboot policies to proceed.

For a mixed persistent tree, runtime selection computes ephemerality down the
logical parent chain and resets every descendant of a tmpfs node while leaving
persistent siblings selected unchanged. Target materialization filters tmpfs
runtime nodes and children of physical nodes already marked ephemeral.
**Current limitation:** when that tmpfs logical node has children, its split
frozen-lower node is not itself marked ephemeral by this filter. Its frozen
representation and persistent descendants can therefore still receive target
copies even though the next boot resets their runtime state. Do not rely on a
mixed ephemeral/persistent tree when persistent-copy exclusion is a hard
requirement; an entirely ephemeral host chain uses the no-metaslot path above.
The deferred-window restriction for an entirely ephemeral chain is documented
in [`auto-update.md`](auto-update.md#ab-upper-readiness-and-deferred-reboots).

## Transactional legacy migration

On the first boot with a legacy shared persistent upper, initial preparation
copies the existing upper and Nix state into the active physical slot's first
generation. Activation then moves legacy paths into
`/var/lib/nix-overlay/legacy-backup` and installs the selected links and binds.
The other slot remains unready until a subsequent update prepares it.

A move is journaled only after it succeeds and the backup exists. `mv` supplies
its copy fallback when source and backup are on different filesystems. Upper,
work and each `db`, `gcroots`, `profiles` and `temproots` activation is recorded;
an interruption replays that journal backwards to restore previous symlinks,
directories and bind mounts, and does not expose the selected-chain readiness
marker. Retrying is idempotent and converges on the migrated generation. Keep
the recovery backup until the migrated upper and a subsequent update/rollback
cycle have been validated; the module does not remove it automatically.

## Garbage collection

`nix-collect-garbage` reaps upper-only paths; the lower image is never
touched (`ignore-gc-delete-failure=true`). When GC deletes an upper copy of
a path that is also valid in the lower, the module's configured
`remount-hook` rebuilds the overlay mount so the merged view stays coherent —
no unhandled "needs remounting" warnings.

## Content-addressing

The lower closure is built content-addressed, and the module adds
`ca-derivations` to the daemon's experimental features so runtime evaluation
(e.g. `nix-env`) works over it — see [`ota.md`](ota.md) for the
evaluation-side requirement.

How the OTA route stages and installs updates:
[`ota.md`](ota.md). Test inventory:
[`doc/technical_details/testing.md`](../technical_details/testing.md).
Historical lifecycle design:
[`wipe-on-cutover`](../../openspec/changes/archive/2026-10-30-wipe-on-cutover/design.md).

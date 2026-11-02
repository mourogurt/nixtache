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

## Upper metaslots and persistence

On an A/B appliance, the physical lower partition's GPT `PARTUUID` selects an
independent upper metaslot. With the default paths, each prepared generation
lives under:

```text
/var/lib/nix-overlay/upper-slots/<partuuid>/generations/<generation>/
  metadata
  host/{upper,work,state,lower-state}
```

The slot's `current` link selects one generation. `/etc/image-version` alone
is not an identity: two slots may contain the same version and different
upper state. A plain reboot of the same slot selects its current upper and
Nix state unchanged; booting an older prepared slot during rollback does the
same, without a reverse wipe or reconcile.

| `upperDir` on | Plain reboot | Prepared OTA update | Rollback |
|---|---|---|---|
| persistent root FS | installs survive | target policy applies | previous slot's upper is selected unchanged |
| ZFS dataset (OpenZFS ≥ 2.2) | installs survive | same persistent-upper policy | same preservation rule |
| tmpfs | upper and all dependent upper state reset | no persistent metaslot is retained | the ephemeral chain resets again |

The upper layer may live on a ZFS dataset: OverlayFS needs `d_type` and
`renameat2` whiteout/exchange, provided by OpenZFS 2.2. `upperDir` and
`workDir` must sit on the SAME filesystem, and the overlay mounts after the
pool import (`zfs-mount.service`). On older ZFS, keep the upper on the ext4
root instead.

## Target preparation across OTA updates

After sysupdate installs a new lower in the inactive slot,
`nixtache-overlay-prepare.service` prepares only that target while the old
slot remains active. The stock reboot-assessment unit requires this service;
after a manual `systemd-sysupdate` installation it can also be run directly:

```bash
systemctl start nixtache-overlay-prepare.service
```

The two policies are:

- `"wipe"` (default): create an empty target upper, work directory and
  upper-owned Nix state, then load the target lower dump. The active upper,
  roots, profiles and databases are not cleared. The new slot starts without
  ad-hoc installs and needs no substituter for preparation.
- `"reconcile"`: quiesce module-managed Nix writers, clone the current active
  upper and Nix state, resume those writers, and verify/repair only the clone
  in a private mount namespace. Roots and per-user profiles are preserved;
  missing closure paths are fetched into the target, never into the active
  upper. Reusing a physical slot for another update clones the then-current
  active generation, not the target's stale prior generation.

  `reconcile` requires a substituter that still serves the OLD references.
  `services.nixtache.runner.deploy.ab.retain` keeps five staged image versions
  by default, but that is separate from NAR retention: configure the binary
  cache and its store GC to retain the old closures needed for repair.

Preparation copies with `--reflink=auto`: supported filesystems share
unchanged blocks, while others need space for a full upper and database copy.
It is not an atomic storage snapshot. Stop custom services that write
directly to the upper rather than through the module-managed Nix daemon
before running a manual reconcile, and keep capacity for the target copy.

A generation becomes `state=ready` only after its complete target chain
validates. An interrupted clone, unavailable substituter or unresolved path
leaves an explicit `state=unready` generation and does not advance readiness
or modify the active upper. Once the cause is fixed, discard that incomplete
attempt by starting a fresh preparation:

```bash
systemctl reset-failed nixtache-overlay-prepare.service
systemctl start nixtache-overlay-prepare.service
```

The retry removes incomplete staging/unready generations; reconcile clones
the latest active state again, while wipe creates another empty target. The
readiness record also contains the lower dump's SHA-256, so replacing a lower
image with the same version but a different dump invalidates the old
generation.

At boot, `nixtache-overlay-select.service` resolves the mounted lower's
`PARTUUID` and selects a ready generation with matching lower metadata. If
the selected slot is unprepared or its dump checksum changed, it attempts
target-only recovery before the lower loader, overlay mount, Nix daemon and
runner consumers start. Failed recovery leaves the upper chain unready and
prevents `boot-complete.target` from blessing the new slot, allowing boot
counting to return to the preserved previous slot.

## Ephemeral chains and migration

With a tmpfs upper, selection resets the upper, work directory, lower-state
and upper-owned Nix state on **every** boot. Dependent overlay layers,
including a runner overlay and its state, are reset as well: no child may
retain records for files lost from an ancestor upper. The loader then reseeds
the current lower, with no image-version comparison or persistent metaslot.

On the first boot after upgrading from a shared persistent upper, migration
copies the existing upper and Nix state into the active physical slot's
initial metaslot. The legacy directories are preserved under
`/var/lib/nix-overlay/legacy-backup`; activation failures leave those sources
available for recovery. The other slot stays unready until an update
prepares it. Retain the backup until the migrated upper and a subsequent
update/rollback cycle have been validated.

There is no carry-over value: a configuration that still sets `"none"` fails
evaluation with the enum naming the two valid values. An unset option uses
`"wipe"`; to retain ad-hoc installs across updates, choose `"reconcile"`
with a suitably retained substituter.

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

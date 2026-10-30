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

Every nixtache appliance image ships its slot closure's store DB dump and
seeds `/nix/var/nix/db` at boot (see [`ota.md`](ota.md)), making the
read-only lower store a first-class readable nix store:

- runtime installs are a **delta**: realizing a path whose closure is
  already valid in the lower downloads only the missing paths into the
  upper layer;
- an OTA swap replaces the lower, so upper paths whose dependencies lived
  only in the OLD lower genuinely break (missing interpreter/library) and
  their DB entries dangle — `upperOnUpdate` below exists exactly for this.

## Upper-layer persistence

| `upperDir` on | Plain reboot | OTA cutover |
|---|---|---|
| persistent root FS | installs survive | `"wipe"` clears them; `"reconcile"` repairs them |
| ZFS dataset (OpenZFS ≥ 2.2) | installs survive | same persistent-upper policy |
| tmpfs | upper files vanish and stale upper-owned Nix state is reset | the same every-boot reset runs before the new lower DB loads |

The upper layer may live on a ZFS dataset (e.g. a data pool with more space
than the root partition): OverlayFS needs `d_type` + `renameat2`
whiteout/exchange from the upper filesystem, which ZFS provides since
OpenZFS 2.2 (older releases refuse or misbehave). `upperDir` and `workDir`
must sit on the SAME dataset, and the overlay mounts after the pool import
(`zfs-mount.service`) — both pinned on a real appliance swap by
`ab-data-pool-vm`. On older ZFS, keep the upper on the ext4 root instead.

## Upper lifecycle across OTA updates: `upperOnUpdate`

For a persistent upper, the lifecycle event is the **cutover boot**, not an
update attempt. `nixtache-overlay-lifecycle.service` compares
`/etc/image-version` with `/var/lib/nixtache/last-boot-image-version`:

- an absent marker records the running version as a baseline without wiping or
  reconciling existing installs;
- a mismatch runs the selected policy and advances the marker only after
  success, so booting an older slot during rollback applies the policy again;
- a match leaves a persistent upper untouched. No-op polls, rejected updates
  and timer ticks do not run the policy because they do not cause a cutover.

The lifecycle marker is deliberately separate from the loader's
`/var/lib/nixtache/lower-db-version`. Loading the current lower DB cannot mark
a reconcile pass complete: if reconcile fails, its older lifecycle marker
still requests a retry after the loader has succeeded.

The two persistent-upper policies are:

- `"wipe"` (default): early in the cutover boot, clear the upper layer, work
  directory and overlay store state under `/nix/var/nix` before the lower-DB
  loader and overlay mount run. The loader then reseeds the running slot's
  records. This is deterministic and needs no substituter, but ad-hoc
  installs do not survive a cutover.
- `"reconcile"`: after the lower DB loads and the overlay mounts, resolve
  gc-root and user-profile targets live from their persistent links. Run
  `nix-store --verify` to invalidate records whose files vanished, then
  `nix-store --repair-path` for only the missing closure paths of those roots;
  present paths are not reinstalled. Recorded profile installables are then
  replayed, so their user-facing tools run again. If the substituter cannot
  serve a path, the unit reports it and fails without blocking the boot or deleting
  unrelated upper content. The lifecycle marker remains pending, so the pass
  retries on the next boot or after
  `systemctl start nixtache-overlay-lifecycle.service` once the cache is
  available.

  `reconcile` requires a substituter that still serves the OLD references.
  `services.nixtache.runner.deploy.ab.retain` keeps five staged image versions
  by default, but that is separate from NAR retention: configure the binary
  cache and its store GC to retain the old closures needed for repair.

For a tmpfs upper, `nixtache-overlay-tmpfs-reset.service` detects the upper's
filesystem with `findmnt -T` and clears the upper-owned Nix state on **every**
boot before the lower-DB loader and overlay mount. The loader reseeds the
current slot even when its version marker is unchanged because the DB is
missing. No upper roots survive to reconcile, and no image-version mismatch is
required. Same-version reboots of persistent uppers remain untouched.

There is no carry-over value: with the shipped lower DB a carried upper
deterministically dangles after a swap. **Upgrade note:** a configuration that
still sets `"none"` fails evaluation with the enum naming the two valid
values; a configuration that never set the option uses `"wipe"` (its persistent
upper is cleared at the next cutover). To keep ad-hoc installs across updates,
choose `"reconcile"` with a substituter configured.

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

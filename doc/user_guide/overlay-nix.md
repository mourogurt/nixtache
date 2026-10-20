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

## The shipped lower DB (world A)

Every nixtache appliance image ships its slot closure's store DB dump and
seeds `/nix/var/nix/db` at boot (see [`ota.md`](ota.md)) — the read-only
lower store is a first-class readable nix store, which is the
upstream-intended overlay design ("world A"):

- runtime installs are a **delta**: realizing a path whose closure is
  already valid in the lower downloads only the missing paths into the
  upper layer;
- an OTA swap replaces the lower, so upper paths whose dependencies lived
  only in the OLD lower genuinely break (missing interpreter/library) and
  their DB entries dangle — `upperOnUpdate` below exists exactly for this.

(The historical "world B" — no lower DB, realize downloading full
closures, the upper surviving swaps by accident of completeness — is what
nixtache appliances ran before the shipped DB; the replication-era suites
that constructed world A by hand now pin the shipped reality.)

## Upper-layer persistence

| `upperDir` on | Plain reboot | OTA swap (default `"wipe"`) |
|---|---|---|
| persistent root FS | installs survive | upper cleared by the policy; `"reconcile"` heals + replays instead |
| ZFS dataset (OpenZFS ≥ 2.2) | installs survive | same policy behaviour (pinned by `ab-data-pool-vm`) |
| tmpfs | installs wiped (by design) | nothing to preserve — overlay remounts clean |

The upper layer may live on a ZFS dataset (e.g. a data pool with more space
than the root partition): OverlayFS needs `d_type` + `renameat2`
whiteout/exchange from the upper filesystem, which ZFS provides since
OpenZFS 2.2 (older releases refuse or misbehave). `upperDir` and `workDir`
must sit on the SAME dataset, and the overlay mounts after the pool import
(`zfs-mount.service`) — both pinned on a real appliance swap by
`ab-data-pool-vm`. On older ZFS, keep the upper on the ext4 root instead.

## Upper lifecycle across OTA updates: `upperOnUpdate`

An update replaces the lower store; pick a policy for the upper layer:

- `"wipe"` (default): before `systemd-sysupdate` writes the inactive slot,
  the upper layer, work dir and the overlay store state (`/nix/var/nix`)
  are cleared. Deterministic, needs no cache — but ad-hoc installs do not
  survive an update (a no-op update leaves the machine fully working; the
  nix daemon is stopped only for the wipe instant). The shipped lower DB
  re-seeds from the new slot's dump at the next boot.
- `"reconcile"`: before the update, gc-roots and profile targets are
  captured; after the reboot a reconcile pass runs `nix-store --verify`
  (drops DB entries whose files are gone and that nothing valid refers to)
  and then re-fetches, for every recorded root, exactly the closure paths
  whose files are absent from the merged store (`nix-store --repair-path` —
  a delta repair: present paths are not touched). If the cache cannot serve
  a path, the reconcile unit fails red — the boot is unaffected and the
  pass retries on the next boot (or a manual
  `systemctl start nixtache-overlay-reconcile`).

  `reconcile` requires a substituter that still serves the OLD references —
  keep the runner cache retaining previous closures (the staging GC already
  keeps the last two sysupdate packages; extend retention if you rely on
  repair).

There is no carry-over value: with the shipped lower DB a carried upper
deterministically dangles after a swap. `"none"` was removed — a
configuration that sets it explicitly fails evaluation with the enum naming
the two valid values; a configuration that never set the option moves to
`"wipe"` (its upper is cleared at the next update). To keep ad-hoc installs
across updates, choose `"reconcile"` with a substituter configured.

## Garbage collection

`nix-collect-garbage` reaps upper-only paths; the lower image is never
touched (`ignore-gc-delete-failure=true`). When GC deletes an upper copy of
a path that is also valid in the lower, the module's configured
`remount-hook` rebuilds the overlay mount so the merged view stays coherent —
no unhandled "needs remounting" warnings.

## Operating notes (world A)

- **Delta installs**: a path already valid in the lower is never copied
  into the upper — only missing paths land there (pinned by the
  `overlay-nix-ab-swap-vm` and `overlay-nix-install-vm` suites).
- **Stale records across swaps**: DB loading is additive, so old-slot
  records accumulate until healed — `nix-store --verify` reports them, the
  `reconcile` pass repairs what the substituter still serves.
- **Content-addressed world**: the lower closure is built
  content-addressed, and the module adds `ca-derivations` to the daemon's
  experimental features so runtime evaluation (e.g. `nix-env`) works over
  it — see [`ota.md`](ota.md) for the evaluation-side requirement.

How the OTA route stages and installs updates:
[`ota.md`](ota.md). Test inventory:
[`doc/technical_details/testing.md`](../technical_details/testing.md).

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
  # upperOnUpdate = "none";                     # "none" | "wipe" | "reconcile"
};
```

The appliance needs a substituter for anything it installs — typically the
runner host's binary cache:

```nix
nix.settings.substituters = [ "https://<runner-host>:5000" ];
nix.settings.trusted-public-keys = [ "<cache public key>" ];
```

## The three lower-DB worlds

What happens across an OTA slot swap depends on which *world* the appliance's
nix database lives in:

| World | Lower store DB | Upper layer contains | After an OTA swap |
|---|---|---|---|
| **A** (upstream-intended) | present | only the delta (deps resolve from the lower) | upper paths whose deps lived only in the old lower **break** (missing interpreter/library); DB entries dangle |
| **B** (nixtache appliance today) | shared with the overlay store | **full closures** (realize cannot see lower paths, so it downloads everything) | upper paths keep working — self-contained by accident |
| **C** (test harness) | host store with DB | mixed | not representative for appliances |

World B is what a nixtache appliance runs today; world A is what any future
image-shipped lower database (or manual DB registration) produces — and what
`upperOnUpdate` below protects against either way. When reading test results,
check which world the test constructs (the suites name it).

## Upper-layer persistence

| `upperDir` on | Plain reboot | OTA swap (`upperOnUpdate = "none"`) |
|---|---|---|
| persistent root FS | installs survive | installs survive (world B); world A danglers possible |
| tmpfs | installs wiped (by design) | nothing to preserve — overlay remounts clean |

## Upper lifecycle across OTA updates: `upperOnUpdate`

An update replaces the lower store; pick a policy for the upper layer:

- `"none"` (default): nothing happens automatically. Today's behaviour —
  fine for world B with a persistent upper, or any tmpfs-upper appliance.
- `"wipe"`: before `systemd-sysupdate` writes the inactive slot, the upper
  layer, work dir and the overlay store state (`/nix/var/nix`) are cleared.
  Deterministic, needs no cache — but ad-hoc installs do not survive an
  update (a no-op update leaves the machine fully working; the nix daemon is
  stopped only for the wipe instant).
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

## Garbage collection

`nix-collect-garbage` reaps upper-only paths; the lower image is never
touched (`ignore-gc-delete-failure=true`). When GC deletes an upper copy of
a path that is also valid in the lower, the module's configured
`remount-hook` rebuilds the overlay mount so the merged view stays coherent —
no unhandled "needs remounting" warnings.

## Known limitations (world B)

- **Lower paths are invisible to nix operations**: realizing a path that
  exists in the lower image downloads a duplicate copy into the upper (or
  fails without a substituter) — the database does not know about lower
  content.
- **The upper and its DB grow across generations**: nothing reclaims space
  relative to new lower images; run GC periodically or use `"wipe"`.
- **Unregistered references**: a manually registered (or `--load-db`-seeded)
  path whose files live only in the current lower becomes a dangling DB
  entry after the next swap — `nix-store --verify` reports it; that is
  exactly the world-A construct the replication suite
  (`vmTests.overlay-nix-ota-invalid-vm`) pins.

How the OTA route stages and installs updates:
[`ota.md`](ota.md). Test inventory:
[`doc/technical_details/testing.md`](../technical_details/testing.md).

# Proposal

## Why

`upperOnUpdate = "wipe"` currently runs the wipe **on the update trigger**,
unconditionally: `nixtache-overlay-preupdate.service` is `wants`+`before`
`systemd-sysupdate.service`, so every start of the sysupdate unit wipes the
upper layer first — including starts where no update exists or none is
applied. Concretely, the upper is wiped when:

- an update is rejected (bad signature, tampered payload — refused before
  any slot write),
- a poll finds nothing new (no-op), and
- `systemd-sysupdate.timer` ticks (~15 min after boot, then every 2–6h,
  plus weekly) even with nothing staged at all.

So a machine whose policy says "wipe the upper at cutover" in fact wipes it
on a schedule. The disposable-upper policy is fine as a policy; wiping
without a cutover is not. A tmpfs upper has the related boot-time coherence
problem: its files disappear on every reboot while the persistent Nix DB can
retain validity records for those missing files, even when the image version
is unchanged.

## What Changes

- The wipe moves from the update trigger to the **first boot into a new
  slot**: a boot-time unit compares `/etc/image-version` with its own
  lifecycle marker and wipes the upper layer + overlay Nix state only on a
  real slot swap. Rejected updates, no-op polls and timer ticks never wipe;
  an absent marker establishes a baseline without wiping existing installs.
- Reconcile uses the same cutover detection and resolves persistent roots
  live instead of pre-capturing them. Its marker is distinct from the lower-DB
  loader's marker so a failed reconcile remains pending and retries.
- Boot ordering makes wipe precede both the lower-DB loader and overlay mount;
  reconcile follows both. A tmpfs upper additionally resets stale upper-owned
  Nix state on every boot before the loader reseeds the current lower DB.
- `systemd-sysupdate.service` loses the `wants`/`after` preupdate wiring and
  the daemon stop/start dance disappears.
- Tests retain the post-swap outcomes and add no-op/rejected controls, tmpfs
  stale-DB reboot coverage and reconcile retry checks.
- Docs describe cutover-time semantics, the distinct markers and ephemeral
  upper behavior.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `overlay-nix`: the two-value upper lifecycle (`"wipe"` default or
  `"reconcile"`) runs at cutover rather than on the update trigger; rejected
  or absent updates leave persistent uppers intact, while ephemeral uppers
  get a clean, reseeded store on every boot.

## Impact

- `modules/overlay-nix/default.nix`: preupdate unit replaced by a cutover
  unit; daemon stop/start dropped; option description rewritten.
- `tests/overlay-nix-ota-invalid-vm.nix`: new no-op/rejected legs; existing
  wipe/reconcile assertions unchanged in outcome.
- Rebased onto the current two-value enum (default `"wipe"`) and the
  `lower-store-db` loader. The loader keeps `lower-db-version`; the lifecycle
  keeps a separate marker because reconcile retry has different completion
  semantics. Unit ordering, not a shared marker, coordinates the two.
- Follow-up question (not this change): the runner's relocated store upper
  (`store.mode = "overlay"`) has the same cross-swap staleness question —
  an equivalent policy may be needed there once `lower-store-db` lands.

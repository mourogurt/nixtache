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
without a cutover is not.

## What Changes

- The wipe moves from the update trigger to the **first boot into a new
  slot**: a boot-time unit compares `/etc/image-version` with a recorded
  marker on the persistent root and wipes the upper layer + the overlay's
  nix state only when they differ (a real slot swap happened). Rejected
  updates, no-op polls and timer ticks never wipe.
- The same cutover detection subsumes the reconcile flow's trigger: the
  pre-update capture unit (which only exists to freeze gc-root/profile
  targets before the post-boot verify mutates the DB) dissolves — the roots
  live on the persistent root and can be resolved live at cutover boot,
  before the reconcile pass runs. (Review decision: unify reconcile onto the
  same mechanism in this change, or keep its marker trigger; see design D3.)
- `systemd-sysupdate.service` loses the `wants`/`after` preupdate wiring;
  the daemon stop/start dance in the wipe script disappears (at boot the
  daemon is not running yet).
- Tests: the overlay suites' post-swap assertions are unchanged by
  construction (the cutover boot state is the same); a new leg pins the
  regression — a sysupdate run with nothing staged (and a rejected signed
  update) leaves the upper intact.
- Docs: `doc/user_guide/overlay-nix.md` lifecycle section describes
  cutover-time semantics.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `overlay-nix`: the upper-lifecycle requirements are re-triggered from
  "update triggered" to "booted into a new slot version", with new scenarios
  pinning that rejected/absent updates leave the upper intact.

## Impact

- `modules/overlay-nix/default.nix`: preupdate unit replaced by a cutover
  unit; daemon stop/start dropped; option description rewritten.
- `tests/overlay-nix-ota-invalid-vm.nix`: new no-op/rejected legs; existing
  wipe/reconcile assertions unchanged in outcome.
- Interacts with the in-flight `lower-store-db` change (it reworks
  `upperOnUpdate` — drops `"none"` — and its lower-DB loader uses the same
  image-version-marker cutover detection): this change's cutover unit and
  that loader should share one marker mechanism. Archive order between the
  two decides whose spec delta lands first; the second rebases.
- Follow-up question (not this change): the runner's relocated store upper
  (`store.mode = "overlay"`) has the same cross-swap staleness question —
  an equivalent policy may be needed there once `lower-store-db` lands.

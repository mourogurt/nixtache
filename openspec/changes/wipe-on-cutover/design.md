# Design

## Context

Current wiring (`modules/overlay-nix/default.nix`): both `upperOnUpdate`
values provision `nixtache-overlay-preupdate.service` (`wants`+`before` on
`systemd-sysupdate.service`), which runs the wipe (or reconcile capture)
unconditionally on every sysupdate start. Upstream `systemd-sysupdate.timer`
can therefore trigger the policy without an update. The wipe script
stops/starts `nix-daemon` around deletion to keep the live DB coherent.

The correct persistent-upper event is not "an update was attempted" but "a
new slot was booted": `/etc/image-version` differs from the lifecycle marker
on the persistent root. A tmpfs upper also needs a same-version boot reset:
its files vanish on every reboot, while `/nix/var/nix` on the persistent root
can retain their old validity records.

## Goals / Non-Goals

**Goals:**

- Wipe happens exactly when a cutover happens: first boot into a slot whose
  version differs from the recorded marker.
- Rejected updates, no-op polls and timer ticks leave persistent uppers
  untouched.
- A tmpfs upper reboots into a clean merged store: stale upper-owned DB/state
  is removed before the current slot's lower DB is reseeded.
- The machine's update flow (CI trigger, idle-gated apply, auto-update poll,
  timer) needs no trigger-side changes — the condition is evaluated at boot.

**Non-Goals:**

- No change to the wipe deletion set or reconcile repair passes beyond the
  ephemeral-state reset and boot ordering required to keep them coherent.
- No runner-store lifecycle policy (follow-up, see proposal Impact).
- No change to the lower-DB dump format; coordinate with its loader through
  explicit unit ordering and distinct markers (D4).

## Decisions

### D1 — Cutover detection: image-version marker on the persistent root

A boot-time oneshot (`nixtache-overlay-lifecycle.service`) compares
`/etc/image-version` with `/var/lib/nixtache/last-boot-image-version`:

- marker absent (including an upgrade on a machine with existing installs) →
  record the running version as the baseline without running an action;
- mismatch → run the configured lifecycle action, then write the marker only
  after success;
- match → no persistent-upper action.

Rollback boots (an older blessed entry) also mismatch → wipe clears any upper
content accumulated since the previous cutover, while reconcile re-heals
against the now-current older lower. Tmpfs reset is the independent every-boot
exception in D6.

### D2 — Wipe at cutover: early-boot, before the overlay mount

The unit runs after `local-fs.target` (and after `zfs-mount.service` for a
pool-resident upper) and before both `nixtache-lower-store-db-load.service`
and `nix-daemon-overlay-mount.service`. Wipe therefore clears state before
the loader reseeds the running slot's DB and before the overlay mounts a
clean upper; the daemon never sees torn state and no stop/start dance is
needed.

The deletion set is unchanged: upper dir, work dir, and the overlay nix
state under `/nix/var/nix` (db, gcroots, profiles, temproots).

### D3 — Reconcile: dissolve the pre-update capture into the cutover boot (decided: unify)

The pre-update capture exists ONLY to freeze the root list before
`nix-store --verify` mutates the DB — but the gcroots/profile links are
files on the persistent root and survive the swap untouched, so the boot
unit resolves them live: resolve-roots → verify → repair, one unit at
cutover. This also fixes the harmless-but-sloppy current behaviour where a
no-op tick arms the marker and reconcile runs pointlessly at the next boot.

Decided at review: UNIFY. One cutover mechanism drives both policies; the
preupdate unit and the old reconcile-arming marker disappear. Reconcile runs
after the lower-DB loader and keeps its hard `after`+`requires` ordering on
the overlay mount — verifying against the bare lower would invalidate every
upper entry. On an unreachable substituter it stays red and retries on the
next boot or manual restart; its lifecycle marker is written only after full
success.

### D4 — Keep lower-DB and lifecycle markers distinct

The loader's `/var/lib/nixtache/lower-db-version` records which lower records
were loaded. The lifecycle's `last-boot-image-version` records which version
completed the overlay policy. They cannot be shared: the loader may finish
before reconcile, but reconcile failure must remain pending for the next
boot. Explicit unit ordering coordinates them; a successful lower-DB load
never consumes the overlay retry marker.

### D5 — Trigger surfaces stay untouched

The deploy action's SSH trigger, the idle-gated `nixtache-ab-apply`, the
auto-update poll and the sysupdate timer all keep starting
`systemd-sysupdate.service` directly; the `wants`/`after` wiring for the
preupdate unit is deleted. `systemd-sysupdate-reboot.service` is likewise
untouched.

### D6 — Tmpfs uppers reset stale state on every boot

After `local-fs.target` and before the lower-DB loader/overlay mount, detect
whether `upperDir` resides on tmpfs with `findmnt -T`. In that case clear the
upper-owned Nix state on every boot even when the image-version marker
matches: the tmpfs files are already empty, so retaining their validity
records cannot be coherent. The loader then recreates `/nix/var/nix/db` from
the running slot dump (its existing missing-DB condition works even when the
version is unchanged), and the overlay mounts clean.

For persistent uppers, same-version boots remain no-ops. For reconcile on
tmpfs, the reset replaces the repair pass because no upper roots survive;
there is no meaningful upper content to reconcile.

## Risks / Trade-offs

- [A realize running during a cutover boot loses its upper progress when the
  wipe fires] → same as today's trigger-time wipe; the boot-time ordering
  (wipe before the daemon serves) makes the window narrower.
- [Reconcile unified onto cutover changes a flow covered by fresh VM
  suites] → the post-boot assertions are identical by construction; the
  trigger legs (marker arming) are re-pinned on the new mechanism.
- [Clock/version confusion: a same-version reinstalled slot] → same version
  → no cutover detected → upper kept — matches the same-version no-op
  contract in `ab-ota`.

## Migration Plan

Consumers on `wipe`/`reconcile` keep their setting; only the timing changes
(trigger → cutover boot). The first boot with the new module records a
baseline without touching existing installs; the first real slot change then
runs the policy. Tmpfs uppers are reset on every boot by design. The current
two-value enum has no migration path for the removed `"none"` value beyond
the documented explicit choice of `wipe` or `reconcile`.

## Open Questions

(none — D3 resolved at review: unify reconcile onto the cutover mechanism.)

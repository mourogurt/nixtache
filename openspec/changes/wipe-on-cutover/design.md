# Design

## Context

Current wiring (`modules/overlay-nix/default.nix`): `upperOnUpdate != "none"`
provisions `nixtache-overlay-preupdate.service` (`wants`+`before` on
`systemd-sysupdate.service`), which runs the wipe (or reconcile capture)
unconditionally on every sysupdate start. Upstream `systemd-sysupdate.timer`
is active whenever `systemd.sysupdate.enable` is set (`OnBootSec=15min`,
`OnUnitActiveSec=2h`, weekly persistent) — so the wipe fires on a schedule,
not on an event. The wipe script stops/starts `nix-daemon` around the
deletion to keep the DB coherent on the live system.

The correct event is not "an update was attempted" but "a new slot was
booted": `/etc/image-version` (rebuilt by activation from the running
toplevel) differs from a marker recorded on the persistent root.

## Goals / Non-Goals

**Goals:**

- Wipe happens exactly when a cutover happens: first boot into a slot whose
  version differs from the recorded marker.
- Rejected updates, no-op polls and timer ticks leave the upper untouched.
- The machine's update flow (CI trigger, idle-gated apply, auto-update poll,
  timer) needs no trigger-side changes — the condition is evaluated at boot.

**Non-Goals:**

- No change to what wipe/reconcile DO (same deletion sets, same repair
  passes) — only WHEN they run.
- No runner-store lifecycle policy (follow-up, see proposal Impact).
- Not touching `lower-store-db`'s loader; this change shares its marker
  mechanism (D4).

## Decisions

### D1 — Cutover detection: image-version marker on the persistent root

A boot-time oneshot (`nixtache-overlay-lifecycle.service`) compares
`/etc/image-version` with `/var/lib/nixtache/last-boot-image-version`:

- marker absent (first boot after install) → treat as cutover (wipe is a
  no-op on an empty upper; reconcile finds no roots) and write the marker;
- mismatch → run the configured lifecycle action, then write the marker;
- match → no-op.

Rollback boots (an older blessed entry) also mismatch → the action runs
again; for wipe that is empty-to-empty, for reconcile it re-heals against
the now-current (older) lower — both consistent with the policy's meaning
("the upper must match the running slot").

### D2 — Wipe at cutover: early-boot, before the overlay mount

The unit runs after `local-fs.target` (the upper's filesystem must be
mounted — same constraint as the existing mount unit; a pool-resident upper
adds `zfs-mount.service` ordering, already pinned by `ab-data-pool-vm`) and
before `nix-daemon-overlay-mount.service`, so the overlay mounts onto a
clean upper and the daemon never sees torn state. The daemon stop/start
dance disappears: at that point in boot the daemon has not started.

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
preupdate unit and the reconcile marker disappear. The reconcile unit keeps
its hard ordering (`after`+`requires` the overlay mount — verifying against
the bare squashFS would invalidate every upper entry) and its degrade-safe
behaviour (red unit on an unreachable substituter, retried on next boot /
manual restart — the retry trigger becomes the marker re-check: the marker
is only written after a fully successful reconcile).

### D4 — Share the marker with `lower-store-db`'s loader

That change's lower-DB loader keys its re-seed off the same comparison
(image-version vs marker). One marker file, written once per boot by
whichever unit runs first, read by both; whichever change lands second wires
into the existing marker instead of introducing a parallel one.

### D5 — Trigger surfaces stay untouched

The deploy action's SSH trigger, the idle-gated `nixtache-ab-apply`, the
auto-update poll and the sysupdate timer all keep starting
`systemd-sysupdate.service` directly; the `wants`/`after` wiring for the
preupdate unit is deleted. `systemd-sysupdate-reboot.service` is likewise
untouched.

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

Consumers on `wipe`/`reconcile` keep their setting; only the timing of the
action changes (trigger → cutover boot). `lower-store-db` removes `"none"`
independently. First boot with the new module writes the marker; the first
real update then wipes/reconciles at the cutover boot as before.

## Open Questions

(none — D3 resolved at review: unify reconcile onto the cutover mechanism.)

# Design

## Context

Current coverage boundaries established by the audit (see proposal.md):

- `tests/ab-ota-migrate-vm.nix` pins the live side of migration (provisioning,
  idempotency, update-machinery readiness, live closure retained) and
  explicitly stops before the first post-migration pull/boot: in-test network
  pulls after a whole-system `switch-to-configuration` are flaky (the switched
  config re-initializes guest networking).
- `tests/ab-runner-compat-vm.nix` documents the R4 skip: verifying the runner
  store after a real appliance swap needs two `mkAppliance` image builds plus
  a multi-boot driver, and there is an unresolved host-side prerequisite —
  nixpkgs' container machinery unconditionally `--bind-ro`s the host's
  `/nix/var/nix/db` and `daemon-socket` into the container, which collides
  with the appliance wiring.
- The appliance image mounts `/` and `/boot` by GPT partlabel (`root`,
  `boot` — `modules/ab-image/default.nix` `cfgForLabel`); the provision module
  creates only the two nix-store slots and treats existing `root`/`esp`/`boot`
  labels as protected. The reference server's disk has FS-label `nixos` /
  `ESP` and unknown GPT partlabels.
- The server runs the runner with `store.mode = "clone"` (upper/clone on
  `/srv`, a ZFS pool), `system.autoUpgrade.enable = true` with
  `allowReboot = true`, and systemd-boot with boot counting already on.

## Goals / Non-Goals

**Goals:**

- Pin the disk-side of live→OTA migration: first OTA boot on a migrated disk,
  both legs (wrong labels → safe rollback; contract honoured → cutover with
  the live generation retained as fallback).
- Un-skip R4: runner store functional across a real appliance slot swap.
- Pin consumer storage outside the slots (ZFS pool) across swaps, including
  OverlayFS-upper-on-ZFS.
- Literal coverage of the overlay reconcile "recorded installables replayed"
  scenario (per-user profile leg).
- Document the migrated-disk contract and the two-phase config flip in
  `doc/user_guide/ota.md` (inline, per the docs capability's
  no-standalone-migration-document rule).

**Non-Goals:**

- No provisioning of root/ESP: `ab-provision` stays store-slots-only.
- No overlay-lifecycle redesign here: no-op/rejected wipes, trigger-side
  preupdate removal, reconcile timing and tmpfs stale-DB handling belong to
  `wipe-on-cutover`.
- No runner-store lifecycle policy beyond proving the existing clone/overlay
  swap contracts.
- The consumer-side server walkthrough (nixos-configuration) is a separate
  change in that repo; here we land the generic contract it follows.
- The post-switch in-test pull flakiness of `ab-ota-migrate-vm` is not
  re-approached; that suite's boundary stands.

## Decisions

### D1 — Migrated-disk cutover gets its own suite, not an extension of `ab-ota-migrate-vm`

New `tests/ab-ota-migrate-boot-vm.nix`, using the driver-created-machine
mechanism of `overlay-nix-ab-swap-vm` (OVMF → ESP fallback → UKI, backdoor
over virtconsole): boot a crafted "legacy" disk image whose GPT partlabels
are deliberately NOT `root`/`boot` (mirroring the server's `nixos`/`ESP`),
provision slots on its free space, stage v2 from the deployer node, pull via
`systemd-sysupdate` (no `switch-to-configuration` — the flaky leg of
`ab-ota-migrate-vm` is sidestepped entirely), reboot.

- Leg A1 (unarmed staging): with the live-era `default nixos-*` pin in
  `loader.conf` (what NixOS's systemd-boot installer always writes —
  `systemd-boot-builder.py` `write_loader_conf`), a staged UKI is NOT
  selected at reboot. This pins the real-world gotcha that staging alone
  never cuts a migrated machine over.
- Leg A2 (armed, labels still legacy): with the pin removed but labels
  still wrong, the first OTA boot must NOT brick the machine — boot
  counting exhausts and the previous entry boots. This pins the rollback
  safety net under the exact failure mode an operator hits.

Arming semantics (confirmed in systemd v261 `boot.c`): entry sort is
tries-exhausted-last, then `strcmp(sort-key)` ascending, then version
descending. The UKI's sort-key is its IMAGE_ID (`abtest`), which orders
before the legacy `nixos` sort-key — so REMOVING the default pin selects
the staged UKI, and an exhausted UKI falls behind the legacy entry. The
`default` glob is deliberately NOT assessment-aware (a UKI-only glob would
reselect a failed image forever), so the documented arming step is "remove
the pin", never "replace it with `default abtest_*.efi`".
- Leg B (contract honoured): relabel the partitions to `root`/`boot`
  (sgdisk, offline-safe), re-arm the exhausted UKI by renaming `+0` back to
  `+tries` (boot counting is filename-based), reboot → v2 boots, is blessed,
  and the legacy Type#1 loader entries remain on the ESP as fallback.
- Leg C (override hatch): instead of relabeling, the consumer config
  `mkForce`-overrides `fileSystems."/"`/`"/boot"` to the existing devices →
  same cutover. Mechanism confirmed in nixpkgs: the UKI cmdline carries the
  literal `root=fstab` (`boot.initrd.systemd.root` default,
  `system/boot/systemd/initrd.nix`), and the initrd's fstab is generated
  from `config.fileSystems` (`tasks/filesystems.nix` `initrdFstab`) — so an
  overridden device flows into the UKI's baked initrd and the appliance
  boots the existing partition.

Alternative considered: extend `ab-ota-migrate-vm` with a reboot leg —
rejected, the suite's own comment records why the post-switch pull is
unreliable, and mixing the live-side and disk-side contracts in one file
muddles both.

### D2 — The label contract: relabel is canonical, `fileSystems` override is the escape hatch

The documented contract for route 2 (existing machine): the target disk must
carry GPT partlabels `root` and `boot` before the first OTA boot — via
`sgdisk --change-name` (canonical; zero module changes, matches the
anywhere/disko layout) or by `mkForce`-overriding `fileSystems."/"` /
`fileSystems."/boot"` devices in the consumer config (escape hatch when
relabeling is not an option; mechanism confirmed — see D1 Leg C). Either way
Leg A proves the failure mode is a safe rollback, not a brick.

Alternative considered: add `rootLabel`/`espLabel` options to ab-image —
rejected for now: the image defaults already match the anywhere layout, and
an option pair widens the surface for a one-time migration step the operator
performs once per machine.

### D3 — R4 un-skip as `tests/runner-store-swap-vm` with clone/overlay variants

The `lower-store-db` work supplies the prerequisite validity records for both
runner modes. The remaining work here is verification and documentation:
finish the real-appliance suite, prove both modes in the full matrix, and keep
the host-side nspawn bind-path guarantee (`modules/runner/store.nix` tmpfiles)
pinned by `tests/runner.nix`.

A real-appliance suite in the `overlay-nix-ab-swap-vm` style: `mkAppliance`
embedding the runner container closure, boot v1, run a trivial CI build
through the relocated store, stage v2, swap, reboot, re-run the build.
Variants: `store.mode = "clone"` (assert the re-clone is additive and the
build works post-swap) and `"overlay"` (assert the merged view is coherent).

### D4 — Data-pool suite doubles as the OverlayFS-on-ZFS pin

`tests/ab-data-pool-vm.nix` uses an appliance with a second virtio disk
carrying a ZFS pool (mirroring `srv-root`): import on v1, write state and run a
mock service reading it; swap to v2 and assert pool imports and state reads;
rollback asserts v1 still imports the pool without `zpool upgrade`. These
assertions are independent of the overlay upper policy.

The overlay leg puts `upperDir`/`workDir` on the pool and explicitly selects
`upperOnUpdate = "reconcile"` with a substituter retaining the old closure.
It asserts mount ordering and a repaired, working upper after the swap. A
separate control uses the default `"wipe"` policy and expects upper content to
be cleared, so the suite cannot accidentally turn a policy violation into a
false persistence proof.

Research basis for expecting the leg green (openzfs/zfs#8648 → #9414):
OverlayFS needs `d_type`, `renameat2` whiteout/exchange flags and no
`d_revalidate` from the upper fs; ZFS gained d_type in 2.1 and full
overlayfs-upper support in **OpenZFS 2.2**. The pinned nixpkgs ships ZFS
2.3/2.4, so support is expected — the leg pins it empirically anyway,
together with the genuinely nixtache-side risk: unit ordering of the overlay
mount after `zfs-mount.service`. Docker's own overlay2 driver blacklist is
irrelevant here (we mount overlayfs directly via Nix's local-overlay-store,
not through a containerd/docker driver), and the server's podman keeps its
native zfs driver — untouched by this.

If the leg surprises us: the documented fallback is the upper layer on the
ext4 root (on the migrated server the existing root partition has all the
space; likewise for the runner store upper). No module default changes
without the evidence.

### D5 — Replay leg folds into the existing reconcile variant, not a new suite

`overlay-nix-ota-invalid-vm` gains a pre-swap `nix profile install` of the
mock tool (a hermetic, RAM-cheap profile-installable package). The reconcile
variant asserts the recorded profile target is replayed post-swap; the wipe
variant asserts the profile is gone after the lifecycle action. Trigger and
cutover semantics themselves are owned by `wipe-on-cutover`.

### D6 — Documentation lands inline in `ota.md`, two-phase flip included

Route 2 gains: the partlabel contract (D2), the mandatory
`system.autoUpgrade.enable = false` (the auto-update assertion already
refuses the combination; an un-gated autoUpgrade reboot on a runner host
kills CI jobs), the two-phase config flip (phase 1: `deploy-target.ab.partitions`
without `ab-image` so the live system keeps nix/switch and provisions slots;
phase 2: import `ab-image` so CI builds the sysupdate-package), and the
staging-window note (between a staged image and the gated apply, an
unrelated reboot cuts over — calver UKIs outrank legacy entries by version
sort). Phase 1 explicitly enables `deploy-target.ab` and boot counting, then
starts `nixtache-ab-provision.service` or reboots before phase 2. `testing.md`
gains the new suite rows. README map unchanged.

### D7 — Slot sizes are absolute at evaluation time

`ab-image.storeSize` and `deploy-target.ab.partitions.slotSize` use the same
absolute-size grammar and reject `%` during evaluation. The image build always
uses the configured value directly: the `hasSuffix "%" → "2G"` fallback and
the assertion bypass for percentages are deleted. The provision script keeps
only its absolute-size-to-bytes path; co-imported modules must agree on the
same absolute size.

This is intentionally breaking for percentage configurations. The upgrade note
tells consumers to choose an explicit size from their capacity plan. Absolute
sizes restore deterministic partition layouts and make the build/runtime
equality assertion meaningful; actual free space remains a runtime check, but
its required byte count is known.

Remove the percentage-only coverage and fixtures rather than preserving the
old behavior: `ab-ota-e2e-percent`, the S4 leg in `ab-provision-vm`, their
matrix entries and percent-specific branches in `ab-ota-e2e.nix`. Replace them
with pure-eval rejection and absolute-mismatch assertions, and remove percent
examples from maintained docs and suite inventories.

### D8 — Auto-update acts on completed sysupdate results

Change the A/B poll to `systemctl start --wait systemd-sysupdate.service`
before reading the journal and setting `installed` or the deferred-reboot
marker. Keep the idle-gated runner-host path unchanged.

For `start < end`, the reboot-window predicate is `now >= start && now < end`;
for `start >= end`, it is `now >= start || now < end`. Cover the exact start,
exact end, before/after, cross-midnight and persistent-catch-up cases with a
cheap scripted test using a controlled clock and a recorded reboot stub, not
only string-presence assertions.

### D9 — Post-rollback recovery preserves the running slot

Do not prescribe bare `systemd-sysupdate vacuum` for a fully installed
boot-failed version: vacuum handles partial instances and does not select the
failed complete version for the operator. Add an explicit recovery path that
enumerates the installed/running versions, refuses ambiguous or running-slot
deletion, removes only the operator-selected failed version, and restores a
valid inactive-slot state. Prefer a sysupdate-supported removal operation if
the pinned version provides one; otherwise own the small cleanup script and
its partition/ESP handling in `deploy-target`.

Extend `ab-ota-rollback-vm` beyond the current stable-rollback assertion:
recover, stage a fixed higher version, and prove the next update writes only
the inactive slot and boots it. Document the same procedure in `ota.md`; the
current hazard warning remains until that procedure is implemented.

### D10 — Test inventories describe executable current contracts

Update `ab-contract` to the two-value `upperOnUpdate` enum and current
lower-DB/overlay behavior, remove graceful-degradation/missing-module branches,
then register it in `checks` and the self-CI report loop. Update the data-pool
suite according to D4 so it distinguishes pool persistence from upper policy.
Test headers and comments describe current behavior rather than expected-red
history.

CA-dependent and KVM suites run in the existing CI runners; local verification
for this change uses static OpenSpec validation and cheap non-CA checks so it
does not duplicate CI's content-addressed world rebuild or consume local disk.

### D11 — Host retain-GC uses the same credential contract as CI

The current host `nixtache-ab-gc.service` reads `signingKeyFile` directly even
though runner jobs receive `sysupdate_signing_key` through `LoadCredential`.
Give the host unit its own conditional `LoadCredential` entry and replace the
script's embedded source path with
`$CREDENTIALS_DIRECTORY/sysupdate_signing_key`. Keep GPG import and detached
signature verification behavior unchanged; `signingKeyFile = null` still
provisions no credential and removes stale signatures.

A configured but unreadable source now fails credential setup before GC runs
rather than silently leaving an unsigned/stale manifest. Pure-eval assertions
pin both host and container credential wiring and the absence of the original
path from the GC script; `ab-staging-vm` proves the generated signature still
verifies. `module-ci-wiring.md` documents the host and job consumers together.

## Risks / Trade-offs

- [Three new heavy KVM suites lengthen the weekly full matrix] → smoke
  subset unchanged (still `ab-ota-e2e` + `overlay-nix-ota-invalid-vm`);
  new suites join the full matrix only.
- [R4 surfaces real module work in `modules/runner/store.nix` (conditional
  bind-mounts)] → scoped as a task here; if the fix changes runner
  behaviour on non-appliance hosts, the `runner` spec delta is revisited
  before implementing.
- [OverlayFS upper on ZFS: supported upstream since OpenZFS 2.2, but the
  residual nixtache-side risks are unit ordering vs `zfs-mount.service` and
  CoW-on-CoW build performance] → D4 pins the mount ordering; performance is
  accepted (nix store = mostly small immutable files); ext4-root fallback is
  documented, no module default changes without evidence.
- [Leg A (rollback on legacy labels) may be flaky if the boot failure mode
  varies: initrd stall vs /boot mount failure] → assert the invariant
  (machine returns to the pre-update entry, update machinery alive), not
  the specific failure path.

## Migration Plan

Most changes are additive fixes, tests and docs. Consumers using percentage
`storeSize`/`slotSize` values must replace them with an explicit absolute size
before upgrading; evaluation rejects the old values with that instruction.
Consumers using absolute sizes keep their layout. The OTA guide gains the
percentage-removal note and the tested post-rollback recovery procedure once
D9 lands.

## Open Questions

- D9 implementation detail: confirm whether the pinned systemd-sysupdate
  exposes a safe complete-instance removal operation. If it does not, use the
  module-owned cleanup script described there; the safety contract and VM
  scenario do not depend on that choice.

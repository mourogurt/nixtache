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
- No module redesign planned; fixes land only if a new suite exposes a real
  bug, as tasks in this change with the specs kept in sync.
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

**STATUS: blocked by the `lower-store-db` change.** Implementing the suite
on a real appliance surfaced a deeper prerequisite than the R4 skip note
recorded: the lower (slot) store ships no nix DB at all, so the runner
container's store is broken in BOTH modes (clone seeds by enumerating the
host DB → empty; overlay's `lower-store=daemon` self-references when no
system daemon can exist). The fix is to ship a build-time lower-store DB in
the appliance image — scoped as its own change (`lower-store-db`); this
group resumes after it. Already landed here: the host-side nspawn bind-path
guarantee (`modules/runner/store.nix` tmpfiles), pinned by tests/runner.nix.

A real-appliance suite in the `overlay-nix-ab-swap-vm` style: `mkAppliance`
embedding the runner container closure, boot v1, run a trivial CI build
through the relocated store, stage v2, swap, reboot, re-run the build.
Variants: `store.mode = "clone"` (assert the re-clone is additive and the
build works post-swap) and `"overlay"` (assert the merged view is coherent).

### D4 — Data-pool suite doubles as the OverlayFS-on-ZFS pin

New `tests/ab-data-pool-vm.nix`: appliance with a second virtio disk carrying
a ZFS pool (mirroring `srv-root`): import on v1, write state + run a mock
service reading it, swap to v2, assert pool imports and state reads;
rollback leg asserts v1 still imports the pool (no `zpool upgrade` — version
drift between slots must not wedge the data). A second leg puts the
overlay-nix `upperDir`/`workDir` on the pool and asserts the merged store
works pre/post swap.

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
mock tool (needs a profile-installable package — a trivial flake-less
`nix profile install --file` expression or a profile built from a store path;
chosen at implementation to stay hermetic and RAM-cheap, per the suite's
existing rationale for preferring `realize`). The reconcile variant then
asserts the recorded profile target is replayed post-swap. The
`none`/`wipe` variants gain the corresponding negative assertions (profile
broken after swap / profile gone after wipe).

### D6 — Documentation lands inline in `ota.md`, two-phase flip included

Route 2 gains: the partlabel contract (D2), the mandatory
`system.autoUpgrade.enable = false` (the auto-update assertion already
refuses the combination; an un-gated autoUpgrade reboot on a runner host
kills CI jobs), the two-phase config flip (phase 1: `deploy-target.ab.partitions`
without `ab-image` so the live system keeps nix/switch and provisions slots;
phase 2: import `ab-image` so CI builds the sysupdate-package), and the
staging-window note (between a staged image and the gated apply, an
unrelated reboot cuts over — calver UKIs outrank legacy entries by version
sort). `testing.md` gains the new suite rows. README map unchanged.

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

Additive tests + docs only; no consumer action required. Consumers already
on the OTA route are unaffected; consumers planning route 2 gain the
contract documentation.

## Open Questions

(none — both audit unknowns resolved: the UKI `root=fstab` mechanism makes
the `fileSystems` override leg viable (D1 Leg C), and OverlayFS-on-ZFS is
supported upstream since OpenZFS 2.2 while the pinned nixpkgs ships 2.3/2.4,
so D4 pins empirically what research already expects (D4).)

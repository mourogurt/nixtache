# Proposal

## Why

The reference consumer (`nixos-configuration`'s `server` — the runner host
itself) is about to migrate from the live/self-update route to the OTA route
(`method = "ab-image"`, gating host). Auditing nixtache's OTA coverage
against that real machine surfaced three gaps: the live→OTA migration suite
stops at provisioning readiness and never boots a migrated disk; the runner
store's behaviour across a real A/B slot swap is a documented skip
(ab-runner-compat R4) on exactly the class of machine the server is; and the
migrated-disk label contract (the appliance mounts `/` and `/boot` by GPT
partlabel `root`/`boot`, while provisioning creates only the two nix-store
slots) is neither pinned by a test nor documented — a first OTA boot on a
disk with legacy labels currently fails or flap-rolls-back for reasons an
operator cannot see.

## What Changes

- **Migration e2e, completed**: a new VM suite pins the first OTA boot on a
  migrated disk — legacy root/ESP labels produce a safe boot-counted
  rollback (never a bricked machine), and with the documented label contract
  honoured the cutover succeeds with the pre-migration generation retained
  as bootable fallback.
- **Runner store across a swap (R4 un-skipped)**: a real-appliance suite
  pins that the runner's relocated store keeps serving CI builds after an
  OTA slot swap (clone mode: additive re-clone; overlay mode: coherent
  merged view), on the runner host — the machine that reboots under its own
  CI.
- **Consumer storage outside the slots**: VM coverage that data filesystems
  outside the A/B slots (a second pool/disk, e.g. the server's ZFS
  `srv-root` with podman's zfs graphroot) import and serve state across
  slot swaps, including an OverlayFS-upper-on-ZFS leg (the server's runner
  store upper would live on that pool).
- **Overlay reconcile, literal coverage**: the reconcile suite gains the
  per-user profile leg (`nix profile install` recorded pre-update, replayed
  post-swap), pinning the spec scenario by the letter, not only via gc-roots.
- **Migration contract documented**: `doc/user_guide/ota.md` route 2 gains
  the migrated-disk requirements (root/ESP partlabel contract or the
  `fileSystems` override, the mandatory `system.autoUpgrade` removal, the
  two-phase config flip: provision first without `ab-image`, then build
  images with it). The consumer-side walkthrough for `nixos-configuration`
  is a separate change in that repo; this change lands the generic contract
  it will follow.

No module behaviour changes are planned. If a new suite exposes a real bug
(e.g. in provisioning or the runner store), the fix lands as a task in this
change with the spec kept in sync.

## Capabilities

### New Capabilities

(none — every gap maps onto an existing capability)

### Modified Capabilities

- `ab-ota`: the migration requirement (`A live-deployed target can move to
  the OTA route`) gains scenarios for migrated disks with legacy partition
  labels (safe rollback; documented label/override contract) and for the
  unplanned-cutover guard on the still-live system; a new requirement owns
  consumer storage outside the A/B slots surviving slot swaps.
- `runner`: new requirement — the runner's relocated store (clone and
  overlay modes) remains functional across OTA slot swaps on an appliance
  runner host.

## Impact

- `tests/`: new `vmTests` suites/variants (migration first-boot,
  runner-store-across-swap, data-pool persistence); `overlay-nix-ota-invalid-vm`
  gains a profile-installable leg. `flake.nix` `vmTests` wiring +
  `.forgejo/workflows/vmtests.yml` matrix entries.
- `doc/user_guide/ota.md` (route 2 contract), `doc/technical_details/testing.md`
  (suite inventory). No README map change expected (no new modules).
- The companion consumer change (server migration walkthrough) lives in
  `nixos-configuration` and depends on the contract documented here.

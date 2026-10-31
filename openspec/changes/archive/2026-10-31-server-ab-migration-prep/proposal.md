# Proposal

## Why

The reference consumer (`nixos-configuration`'s `server` — the runner host
itself) is migrating from live/self-update to OTA (`method = "ab-image"`,
gating host). The migration coverage and subsequent code/doc audit exposed
both missing proofs and defects on that route:

- the migrated-disk and runner-store swap scenarios need to match the actual
  upper-layer lifecycle and rollback behavior;
- percentage-based slot sizes make one configuration produce different
  partition layouts on different disks and bypass the build-time/runtime size
  equality check, so operators cannot reason about capacity before deployment;
- the A/B auto-update poll can inspect sysupdate before installation finishes,
  the non-midnight reboot-window lower bound is reversed, and a post-rollback
  update can select the running oldest slot;
- provisioning omits `slotSize` reduction from its low-space remedies, while
  the dormant `ab-contract` suite still pins removed overlay defaults.

The already-planned `wipe-on-cutover` change owns the overlay lifecycle
redesign (no-op/rejected-update wipes and trigger-side `wants`/`after`). This
change does not duplicate that work.

## What Changes

- **Migration e2e, completed**: a VM suite pins the first OTA boot on a
  migrated disk — legacy root/ESP labels produce a safe boot-counted rollback,
  and honouring the mount contract cuts over with the live generation kept as
  fallback.
- **Runner store across a swap (R4 un-skipped)**: real-appliance suites pin
  clone and overlay store behavior across a slot swap on the runner host.
- **Consumer storage outside the slots**: VM coverage pins data-pool imports
  and service state across swaps and rollback. The upper-intact leg explicitly
  uses `upperOnUpdate = "reconcile"` with a substituter; pool persistence is
  asserted independently of the selected upper policy.
- **Deterministic slot sizing**: `ab-image.storeSize` and
  `deploy-target.ab.partitions.slotSize` accept absolute sizes only. Percent
  values fail evaluation with an actionable error; the silent image-build
  fallback and percent-only test/matrix variants disappear.
- **Correct timer-driven OTA**: the poll waits for sysupdate before reading its
  result, reboot-window comparisons cover before/start/inside/end and
  cross-midnight cases, and the post-rollback recovery path is proven not to
  overwrite the running slot.
- **Provisioning and test contracts**: the low-space diagnostic includes
  reducing the absolute `slotSize`; `ab-contract` is updated to current
  overlay semantics and registered, and the data-pool suite no longer expects
  an upper to survive the default wipe policy.
- **Credential-only manifest signing**: both the in-container deploy action
  and the host `nixtache-ab-gc.service` read the signing key through
  `LoadCredential` / `$CREDENTIALS_DIRECTORY`; the host GC no longer reads the
  original `signingKeyFile` path directly.
- **Overlay reconcile and migration documentation**: retain the completed
  profile-replay and migrated-disk work, updating docs and suite inventories
  for absolute-only sizing and the corrected lifecycle coverage.

## Capabilities

### New Capabilities

(none — every gap maps onto an existing capability)

### Modified Capabilities

- `ab-ota`: migration and storage scenarios are aligned with the mount and
  upper-lifecycle contracts; new requirements own absolute-only slot sizing,
  timer-driven update/reboot correctness, and safe recovery before another
  post-rollback update.
- `runner`: the relocated store (clone and overlay modes) remains functional
  across OTA slot swaps on an appliance runner host, and the A/B signing key
  is consumed through credentials by both CI and host-side retain-GC.

## Impact

- `modules/ab-image/default.nix`, `modules/deploy-target/ab-provision.nix`,
  `modules/auto-update/default.nix`, `modules/runner/ab.nix`: absolute-size
  validation, provisioning diagnostics, timer/reboot correctness, and host-GC
  credential wiring.
- `tests/`: migration, runner-store, rollback, provisioning, data-pool and
  auto-update coverage; `ab-contract` returns to `checks` with current
  defaults. Percent-specific VM variants leave `flake.nix` and
  `.forgejo/workflows/vmtests.yml`.
- `doc/user_guide/{ota,overlay-nix,auto-update}.md` and
  `doc/technical_details/testing.md`: current sizing, recovery and lifecycle
  contracts. README map changes only if the suite overview requires them.
- `wipe-on-cutover` retains ownership of cutover-time wipe/reconcile and
  trigger-side preupdate removal; archive/apply ordering must keep their
  deltas coherent.
- The companion consumer change (server migration walkthrough) lives in
  `nixos-configuration` and uses absolute slot sizes.

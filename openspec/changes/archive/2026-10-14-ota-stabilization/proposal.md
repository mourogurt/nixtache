# Proposal

## Why

The A/B (OTA) route is nixtache's biggest feature and the intended deployment
model for the corporation server, yet three things lag behind the code:

1. **Undefined upper-layer semantics across updates.** With a persistent
   (non-tmpfs) overlay-nix upper, an OTA slot swap replaces the lower store:
   store paths registered/installed against the old lower can end up
   dangling (binaries failing with ENOENT, DB entries claiming validity for
   files that no longer exist in the merged view). No test replicates this,
   and the module offers no mitigation.
2. **Thinnest docs on the biggest feature.** OTA and overlay-nix have no
   user-guide page at all (the README row for `overlay-nix` is linkless), no
   openspec capability, and no glossary vocabulary; the deep material is
   frozen under `doc/archive/`. `migration.md` is dead weight: its live
   sections duplicate deploy.md/auto-update.md verbatim.
3. **Coverage holes + no CI for VM suites.** The OTA route's boot-counting
   *rollback* leg, same-version no-op, protocol-drift skip, interrupted
   updates and live→OTA migration are untested anywhere, and no vmTests
   suite ever runs in CI (KVM was unavailable) — regressions surface only in
   manual runs.

## What Changes

- **Overlay upper lifecycle across OTA updates** (`modules/overlay-nix/`):
  - New enum option (working name `upperOnUpdate`): `"wipe"` — clear upper +
    store-DB entries at update cutover (disposable-upper policy);
    `"reconcile"` — post-boot `nix-store --verify` (auto-invalidate
    danglers) + `--verify --repair` (delta re-fetch of missing refs from
    the substituter) + fallback replay of recorded profile installables.
    Default preserves today's behaviour (no lifecycle action).
  - Pre-capture/wipe unit ordered `Before=systemd-sysupdate.service` on all
    nixtache-owned trigger paths (action SSH trigger, `nixtache-ab-apply`,
    auto-update poll); post-boot reconcile unit after the overlay mount,
    conditioned on the capture marker.
  - The module sets Nix's `remount-hook` (fixes the local-overlay-store GC
    dedup-branch "needs remounting" warning — upper deletions of
    lower-valid paths go unhooked today).
- **Replication research suite** (`tests/overlay-nix-ota-invalid-vm.nix`,
  KVM): mock packages `pkgs_1` (static busybox interpreter, seeded
  lower-only via `nix-store --load-db` validity records — no file
  canonicalisation, no copy-up), `pkgs_2` (shebang consumer realized into
  the upper), `pkgs_3` (v2 lower marker). Asserts the dangling-reference
  failure exists as feared, then that both lifecycle modes prevent/heal it;
  plus GC-before-swap probes pinning Nix 2.34 overlay-GC semantics. Full
  branch matrix: mode × upper location (persistent/tmpfs) × event (OTA
  swap/plain reboot) × upper content (profile-rooted / realized-only /
  seeded lower-synced) × cache availability for repair.
- **OTA e2e coverage gaps** (new vmTests suites, pattern: the
  `ab-ota-e2e`/`ab-deploy` extract-real-action.yml harness): boot-counting
  rollback (tries exhausted → old UKI entry boots), same-version no-op
  (sysupdate installs nothing), protocol-drift skip (new action vs old SSH
  gate → warning, job green), interrupted update recovery (half-written
  inactive slot), live→OTA migration on an existing machine.
- **KVM CI**: `.forgejo/workflows/vmtests.yml` (workflow_dispatch +
  schedule, suite matrix, KVM-labelled runner) + documented runner
  prerequisites (`/dev/kvm` bind into the runner container, host
  `system-features = kvm nixos-test`) and, if warranted by deployment
  ergonomics, a small runner-module convenience option for KVM exposure.
- **Docs**: new `doc/user_guide/ota.md` (concepts: A/B slots, sysupdate
  transfers, UKI + boot counting, signing; first-deploy scenario matrix —
  nixos-anywhere/disko route, existing-disk `ab.partitions.autoInit` route,
  runner-host gating route; CI wiring incl. runtime versioning;
  upgrade/rollback story) and `doc/user_guide/overlay-nix.md` (the
  three-worlds lower-DB model, upperDir persistence semantics, lifecycle
  modes, known hazards); README module-table links; glossary OTA/overlay
  vocabulary.
- **Retire `migration.md`**: §1/§2 (duplicated verbatim in deploy.md /
  auto-update.md) deleted; §3/§4 BREAKING history moved to `doc/archive/`;
  §5 protocol-drift rollout essence absorbed into deploy.md; all live
  references updated (deploy.md, auto-update.md, README documentation-layers
  table, `modules/auto-update` option description + assertion messages).

## Capabilities

### New Capabilities
- `ab-ota`: the OTA route end-to-end — first-deploy scenarios, CI/timer/
  idle-gated upgrade flows, faulty-update scenarios (boot-counting
  rollback, protocol drift, same-version no-op, interrupted update), the
  runtime-versioning contract, and the runner-side staging/signing surface.
- `overlay-nix`: the writable overlay over the read-only appliance store —
  mount/re-enabling semantics, upper persistence modes, upper lifecycle
  across updates (wipe/reconcile), GC/dedup constraints and known hazards.

### Modified Capabilities
- `docs`: the "repository MUST contain a migration document" requirement is
  retired — its live content is superseded (duplicates deleted, BREAKING
  history archived, drift-rollout essence absorbed into deploy.md); the
  user-guide layer requirement's inventory gains `ota.md` and
  `overlay-nix.md`.

## Impact

- **Modules**: `modules/overlay-nix/` (new option + lifecycle units +
  remount-hook); `modules/auto-update/` (doc-reference text fixes only).
- **Tests**: new replication suite + e2e gap suites; `tests/ab-fixture.nix`
  extensions (seeding support, faulty-scenario knobs); `flake.nix`
  `vmTests` wiring; `doc/technical_details/testing.md` inventory updates.
- **CI**: new `vmtests.yml`; deployment prerequisite — a KVM-capable runner
  (zen3 QEMU-VM cluster) with `/dev/kvm` exposure and `kvm nixos-test`
  system features.
- **Docs**: new ota.md + overlay-nix.md; edits to deploy.md,
  auto-update.md, README.md, AGENTS.md (module inventory), GLOSSARY.md,
  testing.md; migration.md removed; additions under doc/archive/.
- **No consumer-facing BREAKING changes**: the new option defaults to
  today's behaviour; migration.md removal changes no code contract (its
  live references are updated in the same change).

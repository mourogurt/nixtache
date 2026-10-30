# Proposal

## Why

`ab-ota-anywhere-vm` — the suite that validates the full first-deploy
lifecycle onto a bare disk (nixos-anywhere: kexec installer → disko A/B
layout → closure copy → nixos-install → first boot → first OTA update) —
has never passed a CI dispatch. Its design premise is that the deployer
VM's in-VM `nix build` of the install flake hash-matches closures
pre-built on the CI host and registered in the deployer's store DB, so
the build is a store no-op and the hermetic (network-less) VMs never need
to fetch anything.

That premise is unachievable in this repository's build mode. The
appliance images are built with `contentAddressedByDefault`, and under
content-addressed (CA) derivations Nix rewrites store path names at every
derivation boundary crossing into flattened "alias" names
(`/nix/store/<rewrite-hash>-<orig-hash>-<name>`). The consequences,
established experimentally (local reproductions of the CI failure):

- the registration dump shipped into the deployer VM records CA closure
  members under alias names, while any in-VM evaluation computes the
  original names — validity lookups never match, and the in-VM build
  plans a full rebuild (observed peak: 1246 derivations) including
  fixed-output tarball fetches that cannot succeed without DNS;
- the host builds the rewritten derivations, so even a bit-identical
  in-VM evaluation produces a derivation hash for which no output exists
  anywhere (proven: a vendored, input-less install flake whose evaluation
  is bit-identical between host and VM still fails with "1 dependency
  failed" on the never-built canonical derivation);
- `--pure-eval` refuses `path:` flake-input fetches, and a store-dir
  flake copy cannot grow a lock file, so the flake cannot resolve its
  nixpkgs/disko inputs inside the VM at all without vendoring.

The suite is therefore parked (excluded from the `vmtests` matrix) and
its install leg redesigned: the value of the suite is the wire protocol
(kexec, disko, closure transfer, nixos-install, first boot, first OTA),
not in-VM evaluation — real nixos-anywhere runs evaluate on the
operator's host, which in the test is the CI host itself.

## What Changes

- Park `ab-ota-anywhere-vm`: remove it from the `vmtests.yml` matrix with
  a comment pointing at this change; the suite stays in `flake.nix`
  (`vmTests`) so it remains locally runnable during the rework.
- Redesign the install leg to perform **no in-VM nix evaluation**: the
  test (evaluating in the single CA context on the host) interpolates the
  pre-built closure paths, and the deployer VM drives the same wire steps
  nixos-anywhere performs (kexec into the installer, disko, closure
  transfer, `nixos-install`).
- Verify during implementation whether `nixos-anywhere`'s CLI accepts
  pre-built closures (store paths) directly; if it does not, drive the
  steps directly, mirroring nixos-anywhere's own test suite, and record
  the dropped coverage (the `--flake` CLI entrypoint) explicitly.
- Re-add the suite to the matrix once it passes locally and in CI.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- **ci-workflows**: adds a parking policy — a VM suite may be excluded
  from the matrix only while an open change tracks its rework, with the
  exclusion site referencing that change; every non-parked matrix suite
  must pass.

## Impact

- Files: `.forgejo/workflows/vmtests.yml` (parking + re-add),
  `tests/ab-ota-anywhere-vm.nix` (install-leg rework, header contract
  rewrite), `tests/ab-anywhere-install.nix` (as needed by the new
  mechanism), `tests/ab-ota-vm-lib.nix` (shared helpers if the rework
  extracts any).
- Coordination: `fix-vmtests-run80-failures` task 6 fixed the CA closure
  *copy* mechanics (`ca-derivations` on both nix sides via the shared
  `modules/runner/nix-features.nix`); that fix stands and is reused by
  the reworked leg. This change owns the evaluation-side redesign that
  the earlier task could not have surfaced (the copy fix unblocked the
  run far enough to expose the deeper alias mismatch).
- Docs: `doc/technical_details/testing.md` (suite mechanics after the
  rework, and the parking policy) per the documentation task rule.

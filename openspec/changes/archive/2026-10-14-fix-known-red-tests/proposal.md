# Proposal

## Why

CI on `main` is red (runs 30/31) for a trivial reason with an outsized blast
radius: the `ab-deploy-drift` suite writes its report to `$out/report`
(a directory at `$out`), while `ci.yml`'s report loop does `cat "$out"` on every
suite — the suite's own checks all pass, but the job dies with
`cat: …: Is a directory`. Separately, `doc/technical_details/testing.md`
carries a "Known red" entry: `ab-ota-anywhere-vm` and the C4 leg of
`ab-ota-verify-vm` fail on the current nixpkgs pin (systemd 261.1) — the
remote `--reboot` trigger no-ops green after the booted-version assessment
instead of discovering the staged update, and a plain update logs
`Signature verification failed` against the action-signed manifest. Two of
the three suites that pin the signed-OTA contract (`ab-ota` capability's
install-and-update requirement, `direct-deploy`'s verify scenarios) are
effectively unenforced.

## What Changes

- `tests/ab-deploy-drift.nix` writes its report **into `$out` as a regular
  file**, restoring the suite-output contract every other suite follows
  (`nix build .#checks.<system>.<suite> && cat ./result`), so the CI report
  loop goes green.
- `ab-ota-verify-vm` and `ab-ota-anywhere-vm` are diagnosed on the current
  tree (the recorded failure mode predates the ota-stabilization commit,
  which already shipped gnupg-on-PATH fixes — the live failure mode must be
  re-established from journals, not assumed) and fixed to green on the KVM
  runner, including any module wiring the diagnosis demands (verifier PATH,
  keyring paths, manifest/transfer shape under systemd 261).
- Cleanup folded in: the duplicated `system.image.id`/`system.image.version`
  block in `tests/ab-ota-verify-vm.nix` (copy-paste artifact, eval-time
  harmless) is removed.
- `doc/technical_details/testing.md`: the "Known red" paragraph is removed
  once both suites are green (its facts move into commit messages per the
  no-changelog-comments rule); the suite table's `ab-deploy-drift` row keeps
  describing coverage, unchanged.

No production-module behaviour is *intended* to change: any module edit is
strictly what the diagnosis shows is required for the already-specified
signed-OTA flow to function under the pinned systemd.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None — `skip_specs: true` is declared in `.openspec.yaml`. The `ab-ota` spec
already requires the anywhere-install → first-signed-update flow, and
`direct-deploy` already requires the verify scenarios; this change makes the
suites that enforce those requirements actually run green again. No
requirement text changes; inventing a delta just to satisfy validation would
be noise.

## Impact

- **Code**: `tests/ab-deploy-drift.nix` (output shape), `tests/ab-ota-verify-vm.nix`,
  `tests/ab-ota-anywhere-vm.nix` (as diagnosis dictates); possibly
  `modules/ab-image/default.nix` and `modules/deploy-target/ab-provision.nix`
  (verifier PATH/keyring wiring) and `.forgejo/actions/deploy-target/action.yml`
  (signing/manifest shape) — only if the KVM diagnosis implicates them.
- **CI**: `ci.yml` "Run module tests" step goes green again; `vmtests.yml`
  matrix gains two reliably-green suites (drops the implicit known-red
  exception).
- **Docs**: `doc/technical_details/testing.md` (Known-red paragraph removal).
- **Risk**: low — test-side changes are hermetic; module-side changes, if
  any, land behind the same KVM suites that verify them.

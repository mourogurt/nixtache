# Proposal

## Why

The `update-flake.yml` reusable workflow diverges from `nix-check.yml` in two
ways that both surfaced in consumer CI runs
(`codemaster/nixos-configuration` runs 864 and 867):

1. **Sandboxing is never probed.** `update-flake.yml` lacks the
   `sandbox-probe` step, so `SANDBOX_OK` is unset and every build action
   (`flake-validation`, `rebuild-configurations`, `rebuild-devshells`) silently
   falls back to `--no-sandbox` — while the same runner probes and builds
   sandboxed under `nix-check.yml`. This contradicts the documented contract
   (`doc/technical_details/sandboxing.md`: every build action self-heals based
   on the probe).
2. **Failures leave no downloadable log.** `nix flake update` and
   `nix flake check` (`flake-validation`) write nothing to `artifacts/`; only
   the rebuild actions do. When validation or the update itself fails before
   any rebuild ran, the `upload-artifact` step finds no files and the run ends
   with "Configuration validation failed!" but no log to inspect.

## What Changes

- Add the `sandbox-probe` step to `update-flake.yml`, guarded by
  `steps.guard.outputs.enabled == 'true'` like the other work steps, placed
  after SSH setup and before the first nix invocation.
- Capture step logs into `artifacts/` for the two steps that currently log
  only to the console:
  - `flake-validation`: tee `nix flake check` output to
    `artifacts/flake-check.log` (console output preserved).
  - `update-flake.yml` "Update Flakes Inputs": tee output to
    `artifacts/flake-update.log`.
- Pre-create `artifacts/` early in `update-flake.yml` so the always-run
  upload step never warns on a missing path.
- Update `doc/technical_details/workflow-mechanics.md` (update-flake row) to
  reflect the probe + log capture, and link the new spec.

## Capabilities

### New Capabilities

- `ci-workflows`: Behavioral contract of the reusable workflows and their
  composite actions — sandbox probing before builds, per-step failure logs in
  the `artifacts/` upload, and consistency between `nix-check.yml` and
  `update-flake.yml` for the shared validate/rebuild pipeline.

### Modified Capabilities

(none)

## Impact

- `.forgejo/workflows/update-flake.yml`: new probe step, log capture on the
  update step, early `artifacts/` creation.
- `.forgejo/actions/flake-validation/action.yml`: log capture (behavioral
  change shared with `nix-check.yml` and `ci.yml` callers — additive only,
  console output unchanged).
- Docs: `doc/technical_details/workflow-mechanics.md`, README map if the
  workflow/action inventory wording changes.
- No NixOS module options added or changed; no consumer migration needed.

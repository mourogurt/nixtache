# Tasks

## 1. Target module: apply-unit guard + gate entry

- [x] 1.1 Add `services.nixtache.deploy-target.minFreeBytes`
  (`types.ints.positive`, bytes, default `5 * 1024**3`) to
  `modules/deploy-target/options.nix`. Verify: eval of a test config prints
  the default and a custom value round-trips.
- [x] 1.2 Guard in `modules/deploy-target/apply.nix`: before
  `nix-env --set`, read `df -B1 --output=avail /nix/store`; below
  `minFreeBytes` → consume the pointer, log available/threshold bytes with
  a garbage-collection hint, exit 1 without touching the profile. Verify: a
  module test in `tests/` drives the unit script with a stubbed low `df`
  and asserts the profile symlink is unchanged and the pointer consumed.
- [x] 1.3 Gate entry in `modules/deploy-target/user.nix`: exact-match
  `df -B1 --output=avail /nix/store` (design D3). Verify: gate script test
  asserts the exact form is allowed and argument/order/redirect variants
  are rejected with the standard message.
- [x] 1.4 Module docs for the new option: `doc/user_guide/deploy.md` option
  table + a pointer from `doc/technical_details/workflow-mechanics.md`,
  linking `openspec/specs/direct-deploy/spec.md`.

## 2. Action: pre-copy check + ssh hygiene

- [x] 2.1 Pin `-o UserKnownHostsFile=$PWD/.deploy-known-hosts` in the
  deploy action's `ssh_opts` and `NIX_SSHOPTS` (design D5). Verify: deploy
  exercised in a HOME-less environment (VM test) produces no `/.ssh`
  warnings and writes the workspace known_hosts.
- [x] 2.2 Pre-copy space check in `_liveApply` (design D1): remote delta
  via `nix path-info --store ssh://… --all` vs local closure, need =
  Σ missing narSize × 1.1 + 512 MiB, conservative full-closure fallback on
  inventory failure. Verify: VM test with a space-starved target errors
  before `nix copy` (no closure data pushed, apply unit not triggered) and
  an ample target deploys normally.
- [x] 2.3 Failure policy (design D2): record `::error::` per failing
  target and continue the loop; the job fails at the end if any target
  errored. Verify: matrix test with one low-disk target — remaining
  targets deploy, the job is red, the log names target/avail/needed.
- [x] 2.4 Docs: `doc/user_guide/deploy.md` (pre-flight check section),
  `doc/user_guide/migration.md` two-phase rollout note (module first, then
  action; `sshGate = "restrict"` transition), linking
  `openspec/specs/direct-deploy/spec.md` and
  `openspec/specs/deploy-user/spec.md`.

## 3. Integration

- [x] 3.1 Full `nix flake check` (including the vmTests suites) green with
  all new scenarios; README updated if the deploy feature summary changes.

## 4. Preset redesign + drift tolerance + glossary (post-implementation grilling)

- [x] 4.1 Runner-side preset: add
  `services.nixtache.runner.deploy.targets.<name>.minFreeBytes`
  (`types.ints.unsigned`, bytes, default `5 * 1024**3`; `0` disables the
  pre-copy check) to `modules/runner/types.nix` and serialize it into
  `NIXTACHE_DEPLOY_TARGETS` in `modules/runner/deploy.nix`. Verify:
  `tests/runner.nix` scenario — default ships in the env JSON, custom value
  and `0` round-trip.
- [x] 4.2 Target-side `0` disables: loosen
  `services.nixtache.deploy-target.minFreeBytes` to `types.ints.unsigned`
  and wrap the apply-unit guard in `mkIf (minFreeBytes > 0)`. Verify:
  `tests/deploy-target.nix` — `0` evaluates and the script omits the guard.
- [x] 4.3 Action two-stage check + drift skip (design D1/D6/D7): read the
  preset from the map (`// 5368709120` default for older runner modules);
  stage 1 pre-build `df` vs preset → per-target `::error::`; stage 2
  post-build need = Σ missing narSize × 1.1 + preset (fallback: full
  closure × 1.1 + preset); preset `0` skips the check; rejected/unparseable
  `df` → distinct exit code → the loop emits a per-target `::warning::`
  with the `sshGate = "restrict"` hint and does NOT count it as failed.
  Verify: runner↔action contract run in `tests/runner.nix` stays green.
- [x] 4.4 VM coverage in `tests/ab-deploy.nix`: matrix run gains a drift
  entry (a second deploy user gated with the REAL gate script minus the df
  entry, derived by text subtraction with a build-time assertion) —
  asserted skipped with warning, absent from the failed-targets summary;
  plus a drift-only run proving the job exits 0. Verify: suite green on
  KVM.
- [x] 4.5 Docs: `doc/user_guide/deploy.md` (preset option row, two-stage
  pre-flight section incl. drift-skip semantics), `doc/user_guide/
  migration.md` §5 (drift now skips with a warning), one guard line in
  `doc/user_guide/auto-update.md` (its activations share
  `nixtache-apply.service`), all linking the openspec specs.
- [x] 4.6 `doc/GLOSSARY.md` seeded with the canonical terms (SSH gate,
  pre-copy disk check, apply-unit disk guard, pointer file, apply unit,
  deploy map, protocol drift, Tier-0, Tier-1); "Terminology" rule in
  `AGENTS.md` (check the glossary before introducing/renaming domain terms;
  update it in the same change); README documentation-layers row.
- [x] 4.7 Re-run `nix flake check --all-systems` + the affected vmTests
  (`ab-deploy`, `auto-update-vm`, `ab-ota-e2e`) green.

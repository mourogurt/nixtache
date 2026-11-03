# Tasks

## 1. Dedicated builder identities

- [x] 1.1 In `modules/runner/store.nix`, declare `nixtache-runner-bld` plus statically numbered builder users only for relocated stores, using GID `32000`, UIDs from `32001`, and the design's `max-jobs`/`"auto"` count formula regardless of `nix.enable`; extend `tests/runner.nix` to pin the default 32 users, enlarged counts, `"auto"`, both host Nix modes, and absence for native stores — verify `nix build .#checks.x86_64-linux.runner` passes
- [x] 1.2 Set `build-users-group = nixtache-runner-bld` and `auto-allocate-uids = false` only in `nix-daemon-custom`'s `NIX_CONFIG`, replacing the appliance root-build branch while preserving feature flags and system-daemon/seeder configuration; replace the root-build eval assertion with coverage for daemon scoping and consumer-enabled automatic UID allocation — verify `nix build .#checks.x86_64-linux.runner` passes
- [x] 1.3 Add host-side UID/GID intersection checks and the `61183` upper-bound assertion, with errors naming the colliding account/ID or excessive builder count; add negative pure-eval scenarios for a host user, host group, and range exhaustion — verify `nix build .#checks.x86_64-linux.runner` proves all three configurations are rejected

## 2. Concurrent-daemon regression coverage

- [x] 2.1 Add `tests/runner-builder-isolation-vm.nix` on a Nix-enabled host with a relocated store: synchronize live host and custom-daemon builders, assert distinct numeric UIDs, trigger real daemon cleanup by cancelling each side in turn, and require the peer builder to survive and complete — verify `nix build .#vmTests.x86_64-linux.runner-builder-isolation-vm` passes in both cleanup directions
- [x] 2.2 Register the new suite in `flake.nix` under `vmTests.x86_64-linux` and in the full (not smoke) `.forgejo/workflows/vmtests.yml` matrix; update `doc/technical_details/testing.md` with its two cleanup directions and a canonical `openspec/specs/runner/spec.md` link — verify the flake attribute and workflow matrix entry have identical names and `nix build .#checks.x86_64-linux.ci-workflow-drift` passes

## 3. Existing runtime builds use the dedicated users

- [x] 3.1 Remove the empty `build-users-group` override from `tests/ab-runner-compat-vm.nix` and make its build proof record that the custom-daemon builder ran as a nonzero dedicated UID — verify `nix build .#vmTests.x86_64-linux.ab-runner-compat-vm` passes without root-build overrides
- [x] 3.2 Remove the empty `build-users-group` override from the shared helper in `tests/runner-store-swap-vm.nix`, retaining the pre/post-swap build assertions — verify both `nix build .#vmTests.x86_64-linux.runner-store-swap-clone-vm` and `nix build .#vmTests.x86_64-linux.runner-store-swap-overlay-vm` pass

## 4. Operational documentation

- [x] 4.1 Update `doc/technical_details/architecture.md` with the custom daemon's dedicated account range, daemon-scoped configuration, and unchanged system-daemon boundary, linking `openspec/specs/runner/spec.md`; verify the store module remains the sole documented owner of these mechanics and the README repository map still needs no change
- [x] 4.2 Extend `doc/technical_details/resources.md` signal-9 diagnosis with the shared-user-namespace scenario, numeric-UID comparison, host/container daemon cleanup evidence, and the declarative collision guard, linking the canonical runner spec; verify the section states the failure scenario before its diagnosis and does not duplicate resource-limit mechanics

## 5. Integration

- [x] 5.1 Run `nix flake check --show-trace --all-systems` and `openspec validate isolate-custom-daemon-builders --strict`; verify both complete successfully after all code, VM, workflow, and documentation updates

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.

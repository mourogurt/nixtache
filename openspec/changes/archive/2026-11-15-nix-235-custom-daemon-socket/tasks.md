# Tasks

## 1. Socket activation contract

- [x] 1.1 Set `systemd.sockets.nix-daemon-custom.socketConfig.FileDescriptorName = "nix-daemon.socket"` in `modules/runner/store.nix` with a self-contained comment explaining Nix's descriptor-name selection; extend the relocated-store scenario in `tests/runner.nix` with the exact descriptor-name assertion while preserving the existing path and native-store checks — verify `nix build .#checks.x86_64-linux.runner` passes and the report contains the new check
- [x] 1.2 Document the custom socket's descriptor-name invariant in `doc/technical_details/architecture.md`, linked to `openspec/specs/runner/spec.md`, and leave `README.md` unchanged because its repository map and overview are unaffected — verify the text describes current behavior without change-history narration or links into the active change directory

## 2. Nix 2.35 runtime regression coverage

- [x] 2.1 In `tests/runner-builder-isolation-vm.nix`, pin only the inner container's `nix.package` to `pkgs.nixVersions.nix_2_35`, include that package in the minimal seeded store, and add a bounded `nix store info` probe through the custom socket before the existing concurrent builds; update the suite's explanatory comments for this version-specific leg — verify `nix build .#vmTests.x86_64-linux.runner-builder-isolation-vm` passes, the handshake completes within its timeout, and both existing builder-isolation cases still succeed
- [x] 2.2 Record the explicit Nix 2.35 socket-activation and builder-isolation leg in `doc/technical_details/testing.md`, linked to `openspec/specs/runner/spec.md` — verify the suite inventory remains otherwise unchanged and the documentation distinguishes this runtime check from pure-eval wiring coverage

## 3. Integration verification

- [x] 3.1 Run `openspec validate nix-235-custom-daemon-socket --strict`, `nix flake check --show-trace --all-systems` and `git diff --check`; review the final diff to confirm that production changes are limited to the custom socket, no cache package or consumer-side `nix-serve` override was introduced, and all maintained-doc links target canonical specs — verify every command succeeds and the scope matches `proposal.md`

# Proposal

## Why

On Nix 2.35 and newer, the relocated runner store's custom daemon can remain active without accepting connections: Nix selects a socket-activated file descriptor by the name `nix-daemon.socket`, while systemd currently supplies the custom unit name `nix-daemon-custom.socket`. CI builds and other clients of the relocated store therefore stall even though the daemon and socket units appear healthy.

## What Changes

- Assign the custom daemon socket's file descriptor the explicit name `nix-daemon.socket`, independently of the existing unit name and relocated socket path.
- Add pure-evaluation coverage for the socket-activation contract and runtime coverage using Nix 2.35, including a bounded connection probe and the existing builds through the custom daemon.
- Document the socket-naming invariant and the Nix 2.35 runtime coverage.
- Preserve all public option shapes, unit names, socket paths and store modes. Leave binary-cache package selection unchanged; any consumer-side `nix-serve` compatibility override is outside this change.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `runner`: a relocated store must pass its socket-activated file descriptor under the name expected by Nix and must serve connections on Nix 2.35 and newer.

## Impact

- `modules/runner/store.nix`: custom daemon socket configuration.
- `tests/runner.nix`: evaluated socket-name assertion.
- `tests/runner-builder-isolation-vm.nix`: explicit Nix 2.35 runtime coverage and a bounded daemon handshake.
- `openspec/specs/runner/spec.md`: relocated-store socket-activation requirement after sync.
- `doc/technical_details/architecture.md` and `doc/technical_details/testing.md`: the socket contract and its verification.
- No README repository-map change, public API migration or cache-package change is required.

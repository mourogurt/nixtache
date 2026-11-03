# Proposal

## Why

The runner container and its host share a user namespace, but their Nix daemons allocate builders through different userpool lock directories. They can therefore assign the same numeric `nixbld*` UID concurrently; when either daemon cleans up a build, its UID-wide `killUser` can SIGKILL the other daemon's builder and compiler processes. The appliance branch compounds the problem by making the custom daemon build as root instead of providing build users.

## What Changes

- Give every relocated-store `nix-daemon-custom` a dedicated in-container builder group and static builder accounts whose numeric UIDs/GID do not use the host's normal `nixbld` range.
- Configure only the custom daemon to use those accounts, in both clone and overlay modes and on both Nix-enabled and Nix-less appliance hosts; disable automatic UID allocation for this daemon so it cannot bypass the dedicated accounts.
- Add evaluation guards against overlap with declaratively allocated host UIDs/GIDs and preserve the container system daemon's existing builder configuration.
- Replace root-build assumptions in existing tests and add a runtime regression that runs host and container builds concurrently, terminates one build, and verifies that the other daemon's builder survives.
- Document the UID-isolation invariant and add UID-collision evidence to the signal-9 diagnostic guidance.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `runner`: relocated-store builds must use dedicated builder identities that cannot be killed through UID cleanup by an independent host or container Nix daemon.

## Impact

- `modules/runner/store.nix`: custom-daemon builder account declarations, ID-collision assertions, and daemon-scoped Nix configuration.
- `tests/runner.nix`: account, range, configuration, native-store, and collision scenarios.
- Runtime VM coverage: a focused concurrent-build cleanup regression plus updates to `ab-runner-compat-vm` and both `runner-store-swap-*` suites to build through the dedicated users rather than forcing root.
- `flake.nix`, `.forgejo/workflows/vmtests.yml`, and `doc/technical_details/testing.md` if the focused regression is added as a new VM suite.
- `doc/technical_details/architecture.md` and `resources.md`: builder-isolation internals and operational diagnosis. No consumer option or store-layout change is planned.

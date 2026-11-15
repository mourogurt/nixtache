# Design

## Context

See `proposal.md` — Why. The custom socket and service deliberately share the `nix-daemon-custom` base name, while the socket listens under the relocated store rather than the system daemon's native path. Nix 2.35 filters socket-activated descriptors by `nix-daemon.socket`; Nix 2.34 accepts descriptors without that filter. Systemd's `FileDescriptorName=` separates the descriptor identity from the unit identity.

The existing `runner-builder-isolation-vm` suite already starts a relocated-store daemon with cache disabled and performs builds through its socket. Its storage seeder copies only the small set of paths needed by those builds, making it a suitable runtime regression suite without another VM entry point.

## Goals / Non-Goals

**Goals:**

- Preserve the custom unit and socket topology while supplying the descriptor name Nix expects.
- Verify both the evaluated systemd directive and actual daemon connectivity with Nix 2.35.
- Keep the production change independent of the consumer's Nix package version.

**Non-Goals:**

- Do not change cache packages, cache protocol behavior or consumer-side `nix-serve` overrides.
- Do not add a public option, rename units, move the socket or introduce a separate VM suite.
- Do not change native-store (`store.path = "/"`) behavior.

## Decisions

### D1: Set the descriptor name explicitly on the existing socket

Set `systemd.sockets.nix-daemon-custom.socketConfig.FileDescriptorName = "nix-daemon.socket"` inside the container's relocated-store configuration. Keep `DirectoryMode` and all other socket settings unchanged.

This is preferable to renaming the unit, which would alter service dependencies and risk confusion with the system daemon. A Nix-version conditional is unnecessary: Nix 2.34 ignores descriptor names, while Nix 2.35 requires the matching name. The inline comment must state the current selection invariant itself, not merely refer to this change or a historical failure.

### D2: Exercise the existing builder-isolation runtime path with Nix 2.35

Pin only the inner container's `nix.package` to `pkgs.nixVersions.nix_2_35` in `tests/runner-builder-isolation-vm.nix`; leave the host package and production defaults untouched. Include the selected inner package in the suite's minimal seeded store so it remains executable after the custom daemon's `/nix` bind. Add a bounded `nix store info` probe through the custom socket before the existing concurrent-build scenarios. The probe fails promptly when no descriptor is accepted instead of leaving the first build to hang until the suite timeout.

The existing builds remain the end-to-end assertion that accepted connections can execute operations, while `tests/runner.nix` asserts the exact evaluated `FileDescriptorName` value. Using `ab-runner-compat-vm` or adding another suite would duplicate heavier clone/setup coverage; enabling the cache would conflate this contract with consumer-side `nix-serve` packaging concerns.

### D3: Document only the durable contract

Add the descriptor-name invariant to the runner store architecture documentation and record the explicit Nix 2.35 leg in the testing inventory. Describe current behavior and coverage, without a resolved-bug narrative. The README repository map remains unchanged.

## Risks / Trade-offs

- [A default-Nix runtime suite can pass while the Nix 2.35 activation path is broken] → Pin the inner container package explicitly in the selected VM suite and keep the bounded handshake before builds.
- [Pinning the whole test to Nix 2.35 could reduce default-version coverage] → Other runner VM suites continue using the default package; only this suite owns the explicit 2.35 activation leg.
- [An unconditional descriptor name could affect older Nix behavior] → Nix 2.34 does not filter by descriptor name, and the socket path and unit topology remain unchanged; the pure-eval suite also retains the existing socket-path assertion.

## Migration Plan

No persistent-state or configuration migration is required. A normal NixOS configuration switch applies the revised socket unit; on a running runner, restart the custom socket and daemon if the switch does not restart them, then run the same bounded `nix store info` probe used by the VM test. Rollback restores the previous unit definition without touching store contents.

# Design

## Context

See `proposal.md` for the failure mechanism and `specs/runner/spec.md` for the required behavior. NixOS containers use the host user namespace by default, so equal numeric UIDs inside and outside the container identify the same kernel user. The host daemon and relocated-store daemon nevertheless maintain independent userpool locks.

`modules/runner/store.nix` currently inherits the container's normal `nixbld` setup when Nix is enabled and explicitly sets an empty `build-users-group` when it is disabled. The latter makes appliance custom-daemon builds run as root. The custom daemon already has its own `NIX_CONFIG`, which provides a configuration boundary that does not affect the system daemon or clone seeder.

## Goals / Non-Goals

**Goals:**

- Give `nix-daemon-custom` deterministic, non-root builder identities in every relocated-store mode.
- Keep numeric builder UIDs disjoint between independent daemons and reject detectable host ID collisions at evaluation time.
- Exercise actual daemon cleanup during concurrent host/container builds.

**Non-Goals:**

- No private user namespace, userpool sharing, consumer-facing ID options, or store-layout change.
- No change to native-store (`store.path = "/"`) daemon behavior.
- No attempt to detect UIDs supplied only by mutable account databases or remote NSS at evaluation time.

## Decisions

### D1 — Declare dedicated static users only for relocated stores

When `store.path != "/"`, the container configuration declares group `nixtache-runner-bld` and users `nixtache-runner-bld<N>` as system accounts. This declaration is independent of `nix.enable`, so appliance containers receive the same accounts as Nix-enabled containers. Native-store configurations receive no additional accounts.

The account count mirrors nixpkgs' static-builder sizing without reading `nix.nrBuildUsers` (whose default is absent when `nix.enable = false`):

```nix
max 32 (if config.nix.settings.max-jobs == "auto" then 0
        else config.nix.settings.max-jobs)
```

Automatic UID allocation does not reduce this static account count. The default configuration therefore creates 32 users.

### D2 — Use a separate numeric ID allocation

The dedicated group has GID `32000`. Builder UIDs start at `32001`; the default set is `32001`–`32032`. Growth for larger `max-jobs` may continue through `61183`, staying above nixpkgs' `nixbld` reservation and below systemd's DynamicUser range. Evaluation rejects a builder count that would exceed that boundary.

Host-side assertions compare the selected builder UIDs with non-null UIDs in `config.users.users`, and GID `32000` with non-null GIDs in `config.users.groups`. A collision fails evaluation and names the account and numeric ID. These assertions include Nix-generated host `nixbld` accounts, even if a consumer changes their normal allocation. UID and GID checks remain in their respective namespaces.

A fixed internal range is preferable to a new public option for this fix: the normal host allocation is known, declarative collisions fail closed, and an operator can reassign the colliding host account. Sharing userpool locks was rejected because it couples independent store lifecycles; a private container user namespace was rejected because it would remap ownership on the bind-mounted persistent store.

### D3 — Scope builder selection to the custom daemon

The existing custom-daemon `NIX_CONFIG` unconditionally adds:

```ini
build-users-group = nixtache-runner-bld
auto-allocate-uids = false
```

This replaces the appliance-only empty `build-users-group`; all existing feature flags remain unchanged. The setting stays out of global `nix.settings` and the rendered `/etc/nix/nix.conf`, so the Nix-enabled container's system daemon keeps its own `nixbld` users and the clone seeder keeps its existing daemon/local-store behavior.

The daemon configuration is valid for both clone and overlay stores because builder identity is independent of store backend. Explicit client overrides in VM build helpers are removed rather than preserved as a second configuration path.

### D4 — Test configuration and real cross-daemon cleanup

Pure-eval scenarios in `tests/runner.nix` cover both host Nix modes, default and enlarged builder counts, `"auto"`, automatic-UID allocation, native-store absence, and host UID/GID collision failures. They also assert that only `nix-daemon-custom` receives the dedicated group.

A new `runner-builder-isolation-vm` suite runs on a Nix-enabled host with a relocated store. It starts instrumented host and custom-daemon builds concurrently, waits until both builders are running under different numeric UIDs, and cancels one client so its daemon performs UID-based cleanup. The peer builder must remain alive and finish. The suite repeats in the opposite cleanup direction and fails if either builder is killed or the UIDs overlap.

The suite is registered in `vmTests.x86_64-linux` and the full VM workflow matrix. Existing appliance and store-swap build proofs drop `--option build-users-group ""`, so their successful non-root builds exercise the new account setup in clone and overlay modes.

### D5 — Document the invariant and diagnosis

`architecture.md` owns the custom-daemon account/configuration boundary. `resources.md` explains the shared-UID-namespace failure surface and tells operators to correlate numeric builder UIDs with host/container daemon cleanup when diagnosing signal 9. `testing.md` lists the focused runtime suite and its cleanup directions. The README map does not change because module responsibilities remain unchanged.

## Risks / Trade-offs

- [A host runtime/NSS account can already use a selected UID without appearing in NixOS configuration] → Evaluation guards cover declarative accounts; documentation identifies the selected range and the need to keep it free on the host.
- [A very large `max-jobs` can exhaust the chosen range] → Fail evaluation at the explicit upper bound instead of allocating into DynamicUser IDs.
- [A cancellation-based VM regression can be timing-sensitive] → Synchronize on live builder markers and observed UIDs before cancelling, then require peer completion rather than relying on a fixed sleep.
- [Existing appliance behavior changes from root builds to unprivileged users] → This is intentional isolation; appliance VM build proofs verify that the relocated store remains buildable without client overrides.

## Migration Plan

Deploy the updated NixOS configuration while CI is idle so the container account database and custom daemon environment switch together; restart the runner container or custom daemon if the normal switch leaves an old daemon instance running. No store data or consumer configuration migration is required. Rolling back restores the previous account and daemon configuration without a store conversion, but also restores the cross-daemon UID-collision risk.

# Build sandboxing

Why the runner's Nix sandbox is off by default, what `enableSandbox = true`
actually does, and how CI self-heals either way. Source of truth:
`modules/runner/sandbox.nix` and
[`.forgejo/actions/sandbox-probe`](../../.forgejo/actions/sandbox-probe/action.yml);
requirements: [`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md).

## The problem

The runner is a NixOS `systemd-nspawn` container. NixOS sets
`nix.settings.sandbox = true` by default, **but nspawn drops `CAP_SYS_ADMIN`
from the container's bounding set**, so `nix-daemon` inside cannot create the
user/mount namespaces + bind-mounts the sandbox needs.

Even with `CAP_SYS_ADMIN` granted back, one subtler blocker remains: nspawn
over-mounts `/proc` subdirs (`/proc/sys`, `/proc/bus`, `/proc/fs`, …)
read-only, which the kernel "locks" (mounts propagated from a more privileged
mount namespace are locked together). Nix's sandbox preflight
(`mountAndPidNamespacesSupported()`) spawns a child with
`CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWUSER` and mounts a fresh procfs **over**
`/proc` — on a masked `/proc` the locked-mount logic blocks it with EPERM
("Mount too revealing" on newer kernels), so every sandboxed build fails with
"this system does not support the kernel namespaces that are required for
sandboxing". `CAP_SYS_ADMIN` does not help — the lock is a mount-namespace
property, not a capability gate.

## The options

| option | default | effect |
|---|---|---|
| `enableSandbox` | `false` | unprivileged container, `nix.settings.sandbox = false`. Working CI out of the box; the container itself is the isolation boundary. |
| `enableSandbox` | `true` (opt-in) | grants `CAP_SYS_ADMIN`, forces `nix.settings.sandbox = true`, applies the daemon `/proc` remount fix (see below). Applies only after a host rebuild AND a container restart (see "Deploy chicken-and-egg"). |
| `additionalCapabilities` | `[]` | extra caps merged on top (e.g. `CAP_NET_ADMIN` for tunnel setup). `sandbox.nix` is the sole owner of the container's capability list — it doesn't auto-merge across modules. |

## The `/proc` remount fix (`enableSandbox = true`)

Each nix daemon's `ExecStart` is wrapped: the daemon's own exec chain runs
`unshare -m`, mounts a fresh procfs over `/proc`, then `exec`s the real
`nix-daemon`. Overmounting `/proc` from the container's own context (no
child user namespace) is allowed, and the fresh proc carries no locked
submounts, so the sandbox preflight's overmount succeeds. Applied to
**both** daemons: the system `nix-daemon` (wrapped in `sandbox.nix`) and the
relocated-store `nix-daemon-custom` (wrapped in `store.nix`, where its
`ExecStart` is owned, when `store.path != "/"`).

The remount MUST live in the daemon's exec chain: systemd clones the mount
namespace **separately for every `Exec*` command** of a unit, so an
`ExecStartPre` mount vanishes with its own process and never reaches the
daemon — the earlier `PrivateMounts`+`ExecStartPre` form of this fix was a
no-op for exactly that reason (the `ExecStartPre` reported success while the
daemon kept seeing the masked `/proc`). Ref:
[NixOS/nixpkgs#405256](https://github.com/NixOS/nixpkgs/issues/405256).

## CI side: runtime probe, not config

Whether builds actually run sandboxed is detected per job by the
`sandbox-probe` action: it builds a tiny unique-name derivation (nothing
caches it, so it always builds locally, using the caller's own pinned
nixpkgs) and exports `SANDBOX_OK=1` (sandbox usable) or `SANDBOX_OK=0` (fall
back) to the job env. The probe derivation's build command must create
`$out` (`mkdir -p $out`) — a bare `true` fails with "builder failed to
produce output path" on every runner, making the probe report a false
negative. Every build action (`flake-validation`,
`rebuild-configurations`, `rebuild-devshells`, `generate-docs`,
`deploy-target`) and nixtache's own `ci.yml` append `--no-sandbox` when
`SANDBOX_OK` ≠ 1 — a runner whose sandbox is broken (or not yet rebuilt with
the fix) self-heals to `--no-sandbox` instead of failing.

The module still exports a static `HAS_SANDBOX_CAP` env (mirrors
`enableSandbox` 1:1), but nothing consumes it — it is legacy; do not wire new
code to it. `SANDBOX_OK` from `sandbox-probe` is the operative flag.

## Deploy chicken-and-egg

The default `false` trades build-level isolation for reliability. Flipping
`enableSandbox` / caps applies only after the host is rebuilt with the
updated module **and the container is restarted** (a plain
`nixos-rebuild switch` on the host does not restart `container@<name>` —
restart it explicitly while no CI job is running), so a first-time rollout
needs one manual rebuild + restart on the server (or an `ab-image` deploy).
The runtime probe means CI stays green on both sides of that switch.

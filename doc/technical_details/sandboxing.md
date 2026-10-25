# Build sandboxing

Why the runner's Nix sandbox is off by default, what `enableSandbox = true`
does, and how CI decides whether builds need `--no-sandbox`. Source of truth:
`modules/runner/sandbox.nix` and
[`.forgejo/actions/sandbox-probe`](../../.forgejo/actions/sandbox-probe/action.yml);
requirements: [`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md)
(module side) and
[`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md)
(CI-side probe contract).

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
| `enableSandbox` | `false` | no `CAP_SYS_ADMIN`; `nix.settings.sandbox = false`. Working CI out of the box; the container itself is the isolation boundary. |
| `enableSandbox` | `true` (opt-in) | grants `CAP_SYS_ADMIN`, forces `nix.settings.sandbox = true`, and applies the daemon `/proc` remount described below. Requires a new container process. |
| `additionalCapabilities` | `[]` | extra caps merged on top (e.g. `CAP_NET_ADMIN` for tunnel setup). `sandbox.nix` is the sole owner of the container's capability list — it doesn't auto-merge across modules. |

`CAP_IPC_LOCK` is always granted, independently of these options, for package
tests that use `mlock`.

## The `/proc` remount (`enableSandbox = true`)

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
daemon. Ref:
[NixOS/nixpkgs#405256](https://github.com/NixOS/nixpkgs/issues/405256).

## CI side: runtime probe, not config

The `sandbox-probe` action attempts a small `runCommand` realization using the
caller's pinned nixpkgs. It exports `SANDBOX_OK=1` when that build succeeds
without an explicit `--no-sandbox`, and `SANDBOX_OK=0` otherwise. The probe
does not inspect `nix.settings.sandbox`: a successful build with sandboxing
disabled also produces `1`. Its fixed output name also means an existing or
substituted output can satisfy the build without executing the builder.

The probe derivation's build command must create `$out` (`mkdir -p $out`) — a
bare `true` fails with "builder failed to produce output path" on every
runner, making the probe report a false negative. Every build action
(`flake-validation`, `rebuild-configurations`, `rebuild-devshells`,
`generate-docs`, `deploy-target`) reads `SANDBOX_OK` and appends
`--no-sandbox` when it is ≠ 1, and so do the inline build steps of nixtache's
own CI (`ci.yml`'s module-test loop and `vmtests.yml`'s suite build). Every
workflow nixtache ships — the reusable `nix-check.yml`, `update-flake.yml`,
`deploy.yml`, `docs.yml` and the self-CI `ci.yml`, `vmtests.yml` — runs
`sandbox-probe` before its first build step. The ordering and vmtests flag
wiring are pinned by `checks.*.ci-workflow-drift`.

The module also exports `HAS_SANDBOX_CAP`, mirroring `enableSandbox`; build
steps use the runtime `SANDBOX_OK` flag instead.

## Applying capability changes

Changing `enableSandbox` or capabilities requires a rebuilt host definition
and a new container process. By default, a `nixos-rebuild switch` that changes
the container definition restarts it. If the consumer disables automatic
container restarts, restart `container@<name>` explicitly while no CI job is
running.

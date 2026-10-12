# Build sandboxing

Why the runner's Nix sandbox is off by default, what `enableSandbox = true`
actually does, and how CI self-heals either way. Source of truth:
`modules/runner/sandbox.nix` and
[`.forgejo/actions/sandbox-probe`](../../.forgejo/actions/sandbox-probe/action.yml).

## The problem

The runner is a NixOS `systemd-nspawn` container. NixOS sets
`nix.settings.sandbox = true` by default, **but nspawn drops `CAP_SYS_ADMIN`
from the container's bounding set**, so `nix-daemon` inside cannot create the
user/mount namespaces + bind-mounts the sandbox needs. Worse: even when
`CAP_SYS_ADMIN` is granted back, nspawn's seccomp / private-users restrict
the `clone(CLONE_NEWUSER|CLONE_NEWNS)` the Nix sandbox needs — so the cap
alone is **not** sufficient on most nspawn setups, and `enableSandbox = true`
produces broken CI ("this system does not support the kernel namespaces
required for sandboxing").

There is a second, subtler blocker: nspawn over-mounts `/proc` subdirs
(`/proc/sys`, `/proc/bus`, `/proc/fs`, …) read-only, which the kernel "locks"
(mounts inherited from a more privileged mount namespace are locked
together). When the sandbox later overmounts `/proc` with a fresh procfs
inside its child user namespace, the locked-mount logic blocks it with EPERM.
`CAP_SYS_ADMIN` does not help — the lock is a mount-namespace property, not a
capability gate.

## The options

| option | default | effect |
|---|---|---|
| `enableSandbox` | `false` | unprivileged container, `nix.settings.sandbox = false`. Working CI out of the box; the container itself is the isolation boundary. |
| `enableSandbox` | `true` (opt-in) | grants `CAP_SYS_ADMIN`, forces `nix.settings.sandbox = true`, applies the daemon `/proc` remount fix (see below). Use ONLY if you've verified the Nix sandbox works in your nspawn (host sysctl `kernel.unprivileged_userns_clone=1`, no `--private-users` conflict, seccomp allows the clone flags). |
| `additionalCapabilities` | `[]` | extra caps merged on top (e.g. `CAP_NET_ADMIN` for tunnel setup). `sandbox.nix` is the sole owner of the container's capability list — it doesn't auto-merge across modules. |

## The `/proc` remount fix (`enableSandbox = true`)

Each nix daemon in the container gets its own mount namespace
(`PrivateMounts = true`) and remounts `/proc` fresh there before starting.
The fresh proc mount is made by root in the container's user namespace → not
locked → the sandbox's child-user-ns `/proc` overmount succeeds. Applied to
**both** daemons: the system `nix-daemon` and the relocated-store
`nix-daemon-custom` (when `store.path != "/"`). Ref:
[NixOS/nixpkgs#405256](https://github.com/NixOS/nixpkgs/issues/405256).

## CI side: runtime probe, not config

Whether builds actually run sandboxed is detected per job by the
`sandbox-probe` action: it builds a tiny unique-name derivation (nothing
caches it, so it always builds locally, using the caller's own pinned
nixpkgs) and exports `SANDBOX_OK=1` (sandbox usable) or `SANDBOX_OK=0` (fall
back) to the job env. Every build action (`flake-validation`,
`rebuild-configurations`, `rebuild-devshells`, `generate-docs`,
`deploy-target`) and nixtache's own `ci.yml` append `--no-sandbox` when
`SANDBOX_OK` ≠ 1 — a runner whose sandbox is broken (or not yet rebuilt with
the fix) self-heals to `--no-sandbox` instead of failing.

The module still exports a static `HAS_SANDBOX_CAP` env (mirrors
`enableSandbox` 1:1), but nothing consumes it — it is legacy; do not wire new
code to it. `SANDBOX_OK` from `sandbox-probe` is the operative flag.

## Deploy chicken-and-egg

Sandbox-in-nspawn is a known hard problem: the default `false` trades
build-level isolation for reliability, and making `true` actually work
requires host-side setup (sysctl, nspawn flags) that nixtache does not yet
automate (tracked as a follow-up — important for cross-compile purity via
binfmt). Also note: any change to `enableSandbox` / caps applies only after
the server is rebuilt with the updated module, so a first-time rollout needs
one manual `nixos-rebuild switch` (or an `ab-image` deploy) on the server.
The runtime probe means CI stays green on both sides of that switch.

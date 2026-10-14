# Design: Fix the enableSandbox /proc remount

## Context

Nix's sandbox preflight (`mountAndPidNamespacesSupported()`, nix 2.34.8
`src/libutil/linux/linux-namespaces.cc`) spawns a child with
`CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWUSER`, makes `/` private, then mounts a
fresh procfs **over** `/proc`. In an nspawn container, `/proc` carries
nspawn's read-only submount masks (`/proc/sys`, `/proc/kcore`, …), which the
kernel "locks" (mounts propagated from a more privileged mount namespace are
locked together — mount_namespaces(7)); overmounting such a `/proc` in the
child user namespace fails with EPERM ("Mount too revealing" on newer
kernels). Overmounting from the container's own (non-child-userns) context
is allowed, which is the entire basis of the fix.

## Decisions

### D1: Wrap `ExecStart`, not `ExecStartPre`

The daemon's own exec chain performs `unshare -m` → `mount proc /proc` →
`exec nix-daemon …`. One process lineage, one mount namespace: the remount
cannot get lost. systemd applies namespace settings per spawned command —
each `Exec*` line receives its own fresh clone of the mount namespace, so an
`ExecStartPre` mount never reaches `ExecStart` (verified on systemd 261.3:
`PrivateMounts`+`ExecStartPre` unit reports `status=0/SUCCESS` for the
remount while the main process's `findmnt -R /proc` still shows nspawn's
masks). Alternative rejected: container-wide `preStart` remount (srd424's
first workaround form) — pollutes the container's default namespace;
`unshare -m` keeps the fresh `/proc` private to the daemon.

`PrivateMounts = true` is dropped: the wrapper's `unshare -m` already
provides the private mount namespace.

### D2: Each daemon's `ExecStart` is wrapped where it is owned

- System `nix-daemon`: its unit comes from nixpkgs' nix module; sandbox.nix
  already overrides it for the fix, and keeps doing so — the wrapper
  references `${config.nix.package}/bin/nix-daemon --daemon` directly.
- `nix-daemon-custom`: its `ExecStart` is defined in store.nix and differs
  by `store.mode` (plain `--daemon` for clone, `--store
  'local-overlay://…'` for overlay). store.nix keeps owning it and applies
  the same wrapper inline, conditional on `enableSandbox`. Alternative
  rejected: a shared internal option holding the wrapper function — adds an
  option (repo rule: description + test) to save three lines of shell.

### D3: Process supervision unaffected

`unshare` execs its argument (no extra fork), and the script `exec`s the
daemon — the PID systemd tracks is the daemon's. `KillMode = process`,
`Delegate`, OOM and scheduling knobs on `nix-daemon-custom` are untouched.

## Risks / Trade-offs

- [systemd semantics vary by version] → the per-command namespace behavior
  was verified on the target (systemd 261.3), and the wrapper form does not
  depend on cross-command namespace sharing at all — it works under either
  semantic.
- [A future nspawn stops masking /proc] → harmless: the wrapper just mounts
  a fresh proc, which is a no-op semantically.

## Migration Plan

1. Land the module + test + doc change here; push to `main`.
2. Consumer (nixos-configuration): bump the `nixtache` flake input, rebuild
   the server, `systemctl restart container@runner` (cap/daemon changes
   require a container restart).
3. The next `nix-check` run's `sandbox-probe` prints `SANDBOX_OK=1`
   (verification lives in the consumer change `enable-runner-sandbox`,
   task 2.2).

Rollback: revert this change in the consumer's input pin; CI self-heals to
`--no-sandbox` via the probe meanwhile.

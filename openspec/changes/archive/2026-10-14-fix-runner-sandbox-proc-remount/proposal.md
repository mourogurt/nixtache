# Proposal: Fix the enableSandbox /proc remount — ExecStartPre never reaches the daemon's mount namespace

## Why

`services.nixtache.runner.enableSandbox = true` still produces
`SANDBOX_OK=0` on a real nspawn runner: every daemon-served build fails with
"this system does not support the kernel namespaces that are required for
sandboxing". Root-caused on the production runner (nixos-configuration
`enable-runner-sandbox` rollout, systemd 261.3, nix 2.34.8):

1. The `/proc` remount fix is expressed as
   `serviceConfig.PrivateMounts = true` + `ExecStartPre = mount proc /proc`.
   But systemd applies namespace settings **per spawned command**: each
   `Exec*` line gets its own fresh clone of the mount namespace. The
   `ExecStartPre` remount therefore happens in a throwaway namespace and is
   gone by the time `ExecStart` runs. Verified live: the daemon's `findmnt
   -R /proc` still shows all nspawn submount masks, and a transient unit with
   the same `PrivateMounts`+`ExecStartPre` pattern reproduces it.
2. With the daemon's `/proc` still masked (nspawn's locked ro submounts),
   nix's `mountAndPidNamespacesSupported()` preflight — `clone(NEWNS|NEWPID|
   NEWUSER)` + fresh-proc overmount of `/proc` — fails with EPERM, so the
   daemon rejects every sandboxed build.
3. The failure was invisible because the `sandbox-probe` action itself was
   broken (its `runCommand … "true"` never created `$out`, failing on every
   runner regardless of sandbox health → unconditional `SANDBOX_OK=0`).
   Fixed separately in `3f50f7c`; with a truthful probe the broken daemon
   fix became visible.

## What Changes

- `modules/runner/sandbox.nix`: replace `PrivateMounts`+`ExecStartPre` with
  an `ExecStart` wrapper on the system `nix-daemon`: the daemon process
  chain itself does `unshare -m` → fresh-proc mount → `exec nix-daemon`
  (the form srd424's revised workaround in nixpkgs#405256 uses), so the
  remount and the daemon share one mount namespace by construction.
- `modules/runner/store.nix`: wrap the relocated-store `nix-daemon-custom`'s
  `ExecStart` the same way (its command differs by `store.mode`, and
  `ExecStart` ownership stays with the file that defines it).
- `tests/runner.nix`: scenario H asserts the wrapper shape on both daemons
  instead of `PrivateMounts`.
- `doc/technical_details/sandboxing.md`: rewrite the fix section — the
  per-command namespace semantics are the non-obvious fact future editors
  need.

## Capabilities

None — `skip_specs: true`: bug fix to an existing mechanism. The
`enableSandbox` contract (sandboxed builds through both daemons when true)
is unchanged; the implementation now actually fulfills it. The `runner`
spec has no sandboxing requirements to update.

## Impact

- Consumers with `enableSandbox = true` (currently: nixos-configuration's
  server) get working sandboxed CI builds after one server rebuild +
  container restart (chicken-and-egg applies as before — the runtime probe
  keeps CI green in the interim).
- No option surface changes; no consumer migration.
- Risk: the wrapper changes the daemons' exec chain (`unshare` stays the
  main process through the `exec`, so systemd PID tracking is unaffected);
  validated live on the target system before writing the module change.

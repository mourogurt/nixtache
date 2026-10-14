# Tasks

## 1. Module fix

- [x] 1.1 `modules/runner/sandbox.nix`: drop the `procFix` attrset
  (`PrivateMounts` + `ExecStartPre`). Wrap the system `nix-daemon`'s
  `ExecStart` (when `enableSandbox`): `unshare -m` a shell snippet that
  mounts fresh proc and `exec`s `${config.nix.package}/bin/nix-daemon
  --daemon`. Rewrite the mechanism comment: systemd clones the mount
  namespace per `Exec*` command, so `ExecStartPre` mounts never reach the
  daemon — the daemon's own exec chain must do the remount.
- [x] 1.2 `modules/runner/store.nix`: apply the same wrapper to
  `nix-daemon-custom`'s `ExecStart` when `cfg.enableSandbox` (both
  `store.mode` variants: `--daemon` and `--store 'local-overlay://…'`).
  Keep `BindPaths`, `Delegate`, OOM/scheduling knobs untouched.

## 2. Tests

- [x] 2.1 `tests/runner.nix` scenario H: replace the `PrivateMounts`
  assertions with wrapper-shape assertions — both daemons' `ExecStart`
  contains `unshare` and a fresh-proc mount when `enableSandbox = true`
  (and the custom daemon only when `store.path != "/"`). Add the negative
  counterpart to scenario I (`enableSandbox = false` → no wrapper, daemon
  `ExecStart` untouched). Verify: `nix build .#checks.x86_64-linux.runner`
  passes.

## 3. Docs

- [x] 3.1 Rewrite the "`/proc` remount fix" section of
  `doc/technical_details/sandboxing.md`: the fix is an `ExecStart` wrapper
  (`unshare -m` + mount + `exec`) on both daemons; state plainly that
  systemd gives each `Exec*` command a fresh mount-namespace clone, which
  is why `ExecStartPre` cannot work. Keep the probe section accurate (probe
  fixed in `3f50f7c` — mention the `$out` requirement for the probe
  derivation's build command). Link `openspec/specs/runner/spec.md`.

## 4. Validate

- [x] 4.1 `nix flake check --show-trace --all-systems` passes; commit + push.
  Consumer-side verification (pin bump, container restart, `SANDBOX_OK=1`)
  is tracked in nixos-configuration's `enable-runner-sandbox` change — do
  not duplicate it here.

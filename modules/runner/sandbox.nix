# Build sandboxing inside the runner container.
#
# NixOS enables `nix.settings.sandbox` by default, but systemd-nspawn drops
# CAP_SYS_ADMIN from the container's bounding set, and its read-only /proc
# submount masks break nix's sandbox preflight even when the cap is granted
# back (mechanism: doc/technical_details/sandboxing.md). So the default is
# `enableSandbox = false` (working CI, builds run unsandboxed inside the
# container which is itself the isolation boundary). `enableSandbox = true`
# grants the cap and wraps both nix daemons with the fresh-/proc remount.
# HAS_SANDBOX_CAP env (instances.nix) tells the reusable actions
# whether to keep sandboxing on (1) or append --no-sandbox (0).
#
# This module is the SOLE owner of `containers.<name>.additionalCapabilities`
# (a list, which doesn't auto-merge across modules) and the forced
# `nix.settings.sandbox`.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;
in
{
  options.services.nixtache.runner = {
    # --- Build sandboxing ---------------------------------------------------
    enableSandbox = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether Nix builds inside the container run sandboxed.

        - `false` (default): keeps the container unprivileged (no
          `CAP_SYS_ADMIN`), forces `nix.settings.sandbox = false`, and exports
          `HAS_SANDBOX_CAP=0` so the reusable CI actions append `--no-sandbox`.
          The runner container itself is the isolation boundary, so unsandboxed
          builds inside it are acceptable.
        - `true`: grants `CAP_SYS_ADMIN` to the container, forces
          `nix.settings.sandbox = true`, exports `HAS_SANDBOX_CAP=1`, and wraps
          both nix daemons' `ExecStart` so each replaces the nspawn-masked
          `/proc` with a fresh procfs before starting (the masked `/proc`
          otherwise makes nix's sandbox preflight fail — mechanism:
          `doc/technical_details/sandboxing.md`). Applying this requires a
          host rebuild AND a `container@<name>` restart.
      '';
    };

    additionalCapabilities = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "CAP_NET_ADMIN" "CAP_MKNOD" ];
      description = ''
        Extra capabilities to grant the container, merged on top of the
        `CAP_SYS_ADMIN` that `enableSandbox = true` adds automatically. See
        {manpage}`capabilities(7)` and {manpage}`systemd-nspawn(1)`.
      '';
    };
  };

  config = mkIf cfg.enable {
    # One container literal: the capabilities grant + the forced sandbox
    # setting. Single use of the dynamic key `${cfg.containerName}` (Nix
    # forbids two path-assignments sharing a dynamic prefix inside one
    # literal). `additionalCapabilities` is a list and does not auto-merge
    # across modules — it MUST be set in exactly one place (here).
    containers.${cfg.containerName} = {
      # CAP_SYS_ADMIN (when enableSandbox) so nix-daemon inside the container
      # can create the user/mount namespaces + bind-mounts that Nix's build
      # sandbox requires. systemd-nspawn drops CAP_SYS_ADMIN by default, and
      # `nix.settings.sandbox` defaults to `true` on NixOS — without the cap
      # every `nix build` / `nix flake check` fails with "this system does not
      # support the kernel namespaces that are required for sandboxing". Any
      # consumer-supplied additionalCapabilities are merged on top.
      #
      # CAP_IPC_LOCK is granted unconditionally: nspawn drops it by default,
      # and package test suites that lock secure memory (libgcrypt's
      # t-secmem/t-sexp, gnupg's secmem) then fail with a bare "General
      # error" from mlock(2). A CI runner building the world will hit these;
      # the capability only lifts RLIMIT_MEMLOCK, it widens no other
      # privilege, and the container remains the isolation boundary.
      additionalCapabilities =
        cfg.additionalCapabilities ++ optional cfg.enableSandbox "CAP_SYS_ADMIN" ++ [ "CAP_IPC_LOCK" ];

      config = { config, lib, pkgs, ... }:
        {
          # Owned by enableSandbox. Forced so it tracks the cap granted to the
          # container 1:1 (sandbox without the cap fails; cap without sandbox is
          # a pointless privilege).
          nix.settings.sandbox = lib.mkForce cfg.enableSandbox;

          # Make the Nix sandbox ACTUALLY work under systemd-nspawn. nspawn
          # over-mounts /proc subdirs (/proc/sys, /proc/bus, /proc/fs, ...) read-only,
          # which the kernel "locks" (mounts propagated from a more privileged
          # mount namespace are locked together). Nix's sandbox preflight
          # (mountAndPidNamespacesSupported: clone(NEWNS|NEWPID|NEWUSER), then a
          # fresh-proc overmount of /proc) fails with EPERM on such a /proc →
          # "this system does not support the kernel namespaces that are required
          # for sandboxing". CAP_SYS_ADMIN alone does NOT fix this (the lock is a
          # mount-namespace property, not a capability gate).
          #
          # Fix: the daemon's own exec chain replaces /proc with a fresh procfs
          # before starting — unshare -m, mount, exec. Overmounting /proc from the
          # container's own context (no child user namespace) is allowed, and the
          # fresh proc carries no locked submounts, so the preflight's overmount
          # succeeds. The remount MUST live in the daemon's exec chain: systemd
          # clones the mount namespace separately for every Exec* command of a
          # unit, so an ExecStartPre mount vanishes with its own process and never
          # reaches the daemon. Ref:
          # https://github.com/NixOS/nixpkgs/issues/405256
          #
          # The relocated-store `nix-daemon-custom` (store.nix, present when
          # store.path != "/") gets the same wrapper where its ExecStart is owned.
          systemd.services.nix-daemon = lib.mkIf cfg.enableSandbox {
            serviceConfig.ExecStart = [
              ""
              "${lib.getExe' pkgs.util-linux "unshare"} -m ${pkgs.writeShellScript "nix-daemon-fresh-proc" ''
                ${lib.getExe' pkgs.util-linux "mount"} proc -t proc /proc
                exec -a nix-daemon ${lib.getExe' config.nix.package "nix-daemon"} --daemon
              ''}"
            ];
          };
        };
    };
  };
}

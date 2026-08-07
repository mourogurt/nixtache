# Build sandboxing inside the runner container.
#
# NixOS enables `nix.settings.sandbox` by default, but systemd-nspawn drops
# CAP_SYS_ADMIN from the container's bounding set AND restricts the
# clone(CLONE_NEWUSER|CLONE_NEWNS) syscalls the sandbox needs (seccomp /
# private-users). The result: every `nix build` / `nix flake check` fails with
# "this system does not support the kernel namespaces that are required for
# sandboxing". Crucially, granting CAP_SYS_ADMIN alone does NOT fix this on most
# nspawn setups — so the default is `enableSandbox = false` (working CI, builds
# run unsandboxed inside the container which is itself the isolation boundary).
# `enableSandbox = true` is opt-in for setups where the sandbox has been
# verified to work (host sysctl, no private-users conflict, seccomp allows the
# clone flags). HAS_SANDBOX_CAP env (instances.nix) tells the reusable actions
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
          This is the default because systemd-nspawn restricts the
          `clone(CLONE_NEWUSER|CLONE_NEWNS)` the Nix sandbox needs — granting
          `CAP_SYS_ADMIN` alone (the `true` case) is NOT enough on most nspawn
          setups, and `true` produces broken CI ("this system does not support
          the kernel namespaces required for sandboxing"). The runner container
          itself is the isolation boundary, so unsandboxed builds inside it are
          acceptable.
        - `true`: grants `CAP_SYS_ADMIN` to the container, forces
          `nix.settings.sandbox = true`, exports `HAS_SANDBOX_CAP=1` (actions
          keep sandboxing on). Opt-in ONLY if you have verified the Nix sandbox
          actually works in your nspawn setup (e.g. host sysctl
          `kernel.unprivileged_userns_clone=1`, no `--private-users` conflict,
          seccomp allows the clone flags). Otherwise leave `false`.
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
      additionalCapabilities =
        cfg.additionalCapabilities ++ optional cfg.enableSandbox "CAP_SYS_ADMIN";

      config = { lib, ... }: {
        # Owned by enableSandbox. Forced so it tracks the cap granted to the
        # container 1:1 (sandbox without the cap fails; cap without sandbox is
        # a pointless privilege).
        nix.settings.sandbox = lib.mkForce cfg.enableSandbox;
      };
    };
  };
}

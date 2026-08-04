# Build sandboxing inside the runner container.
#
# NixOS enables `nix.settings.sandbox` by default, but systemd-nspawn drops
# CAP_SYS_ADMIN from the container's bounding set, so the daemon inside cannot
# create the user/mount namespaces the sandbox needs — every `nix build` /
# `nix flake check` then fails with "this system does not support the kernel
# namespaces that are required for sandboxing". These two options make the
# trade-off explicit: enableSandbox=true (default) grants the cap and keeps the
# sandbox on; enableSandbox=false keeps the container unprivileged at the cost
# of unsandboxed builds (the CI actions detect this via HAS_SANDBOX_CAP and
# fall back to --no-sandbox).
#
# This module is the SOLE owner of `containers.<name>.additionalCapabilities`
# (a list, which doesn't auto-merge across modules) and the forced
# `nix.settings.sandbox`. HAS_SANDBOX_CAP env is set by instances.nix.
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
      default = true;
      description = ''
        Whether Nix builds inside the container run sandboxed.

        - `true` (default): grants `CAP_SYS_ADMIN` to the container (required
          for the Nix build sandbox under systemd-nspawn), forces
          `nix.settings.sandbox = true`, and exports `HAS_SANDBOX_CAP=1` to
          every CI job so the reusable actions keep sandboxing on.
        - `false`: keeps the container unprivileged (no `CAP_SYS_ADMIN`), forces
          `nix.settings.sandbox = false`, and exports `HAS_SANDBOX_CAP=0`; the
          CI actions then append `--no-sandbox` (legacy/relaxed mode).

        Use `false` only if your threat model forbids granting `CAP_SYS_ADMIN`
        (a powerful capability) to the runner container. The default gives a
        working sandbox out of the box.
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

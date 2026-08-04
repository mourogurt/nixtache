# Orchestrator for the Forgejo/Gitea Actions runner module.
#
# This file is the single entry point re-exported as `nixosModules.runner`. It
# owns the container shell + the "identity" options (URL, container/package,
# resource limits, base nix settings) and imports the per-responsibility
# sub-modules, each of which contributes its own slice of `options` and its
# own slice of the SAME container via mkMerge. The NixOS container option
# `containers.<name>.config` merges every contribution into one container
# evaluation (see nixpkgs nixos-containers.nix: its `merge` concatenates all
# definitions into the inner `eval-config` modules list).
#
# Public API + option surface are identical to the former monolithic
# `modules/runner.nix` — consumers and tests are unchanged.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;

  # Host values that must propagate into the container (evaluated on the host).
  system_version = config.system.stateVersion;
  system_features = config.nix.settings.system-features;
in
{
  imports = [
    ./store.nix
    ./cache.nix
    ./ssh.nix
    ./sandbox.nix
    ./known-hosts.nix
    ./instances.nix
  ];

  options.services.nixtache.runner = {
    enable = mkEnableOption "Forgejo Actions runner in a NixOS container with a detached nix store and binary cache";

    # --- Forgejo connection -------------------------------------------------
    forgejoUrl = mkOption {
      type = types.str;
      example = "http://localhost:3000";
      description = ''
        URL of the Forgejo instance every runner instance registers against
        (shared by all `instances.*`). Typically `http://localhost:<port>`
        when Forgejo runs on the same host.
      '';
    };

    # --- Runner identity & behaviour ---------------------------------------
    containerName = mkOption {
      type = types.str;
      default = "runner";
      description = "Name of the NixOS container (and the `container@<name>` systemd unit).";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.forgejo-runner;
      defaultText = lib.literalExpression "pkgs.forgejo-runner";
      description = "forgejo-runner package used by all instances (`services.gitea-actions-runner.package`). Set to `pkgs.gitea-actions-runner` for a Gitea server.";
    };

    hostPackages = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [
        bash
        coreutils
        curl
        gawk
        gitMinimal
        git-lfs
        gnused
        wget
        nix
        nodejs
        jq
        openssh
        nixos-rebuild
      ];
      defaultText = lib.literalMD "see module source";
      description = "Packages available to jobs running on this runner.";
    };

    runnerTimeout = mkOption {
      type = types.str;
      default = "72h";
      description = "Runner job/shutdown timeout.";
    };

    logLevel = mkOption {
      type = types.str;
      default = "debug";
      description = "Runner log level (also applied to job_level).";
    };

    # --- Container resources -----------------------------------------------
    memoryMax = mkOption {
      type = types.str;
      default = "60G";
      description = "`MemoryMax` for the `container@<name>` unit.";
    };

    memoryHigh = mkOption {
      type = types.str;
      default = "58G";
      description = "`MemoryHigh` for the `container@<name>` unit.";
    };

    timeoutStartSec = mkOption {
      type = types.str;
      default = "1d";
      description = "`TimeoutStartSec` for the `container@<name>` unit.";
    };

    # --- nix settings inside the container ---------------------------------
    nixSettings = mkOption {
      type = types.attrs;
      default = {
        hashed-mirrors = [ "https://ustc.edu.cn" ];
        substituters = [
          "https://cache.nixos.org/"
          "https://mirror.sjtu.edu.cn/nix-channels/store"
          "https://mirrors.ustc.edu.cn/nix-channels/store"
          "https://mirrors.cernet.edu.cn/nix-channels/store"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        ];
        max-jobs = 1;
        cores = 8;
      };
      defaultText = lib.literalMD "see module source";
      description = ''
        Extra `nix.settings` applied inside the container. The module forces
        `experimental-features`, `trusted-users`, `system-features` and
        `sandbox` on top of these. Include your binary cache (`substituters` +
        `trusted-public-keys`) here if you want the runner to consume it.

        Do NOT set `sandbox` here — it is owned by `enableSandbox`.
      '';
    };
  };

  config = mkIf cfg.enable {
    containers.${cfg.containerName} = {
      autoStart = true;

      # `system_version` / `system_features` are evaluated on the host and
      # propagated verbatim into the container. specialArgs merges across all
      # sub-modules, so every container-config contribution can destructure
      # them (most use `...` and ignore them).
      specialArgs = {
        inherit system_version system_features;
      };

      # Base container config: nix gc/optimise/settings + stateVersion.
      # Sub-modules (store/cache/ssh/sandbox/known-hosts/instances) inject
      # their own keys into this same attrset via mkMerge.
      config =
        { config, lib, pkgs, system_version, system_features, ... }:
        {
          nix = {
            gc = {
              automatic = true;
              dates = "*-*-01 04:00";
              options = "--delete-older-than 30d";
            };
            optimise = {
              automatic = true;
              dates = [ "monthly" ];
            };
            settings = mkMerge [
              cfg.nixSettings
              {
                experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                trusted-users = [
                  "root"
                  "gitea-runner"
                  "@users"
                ];
                system-features = system_features;
                # `sandbox` itself is forced by sandbox.nix (it tracks the
                # CAP_SYS_ADMIN grant 1:1 — sandbox without the cap fails; cap
                # without sandbox is a pointless privilege).
              }
            ];
          };

          system.stateVersion = system_version;
        };
    };

    # Container resource limits (host side).
    systemd.services."container@${cfg.containerName}".serviceConfig = {
      TimeoutStartSec = lib.mkForce cfg.timeoutStartSec;
      MemoryMax = cfg.memoryMax;
      MemoryHigh = cfg.memoryHigh;
    };
  };
}

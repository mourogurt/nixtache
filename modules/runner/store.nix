# Detached nix store for the runner container.
#
# Owns `store.path` / `store.hostBackup` and the entire relocated-store
# machinery: when `store.path != "/"` the store lives at `<path>/nix` and a
# custom `nix-daemon` + storage oneshot + socket run inside the container,
# with a `BindPaths` bind onto /nix injected into every `gitea-runner-*`
# service and `nix-serve`. When `store.path == "/"` the container reuses its
# system nix-daemon and this module contributes nothing.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;

  # Enabled runner instances — each `gitea-runner-<name>` service gets the
  # relocated-store BindPaths + custom-daemon dependency when customStore.
  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;

  # Whether the nix store is relocated away from the native /nix. The store
  # lives at <path>/nix, so it is native iff path == "/". When false we reuse
  # the container's system nix-daemon and skip the custom daemon + storage
  # oneshot + BindPaths injection.
  customStore = cfg.store.path != "/";

  # systemd BindPaths spec that re-exposes the relocated store (<path>/nix)
  # at /nix. nix itself reconstructs the /nix suffix for `nix copy --to <path>`.
  bindPath = "${cfg.store.path}/nix:/nix";
in
{
  options.services.nixtache.runner.store = {
    # Base directory that backs the relocated nix store. The actual store
    # lives at <path>/nix (nix reconstructs the /nix suffix, both for
    # `nix copy --to <path>` and for the bind mount). Set to "/" to keep the
    # store at the native /nix and reuse the container's system nix-daemon.
    path = mkOption {
      type = types.str;
      example = "/srv";
      description = ''
        Base directory inside the container that backs the nix store. The
        store itself lives at `<path>/nix` (nix appends the suffix).

        - `"/"` → store at the native `/nix`: reuse the container's system
          `nix-daemon` (no custom daemon, no storage oneshot, no BindPaths).
        - anything else (e.g. `"/srv"`) → relocate the store to
          `<path>/nix` and run a custom `nix-daemon` + storage oneshot,
          injecting a `BindPaths` bind onto `/nix` into the working services.

        Mandatory: must not be empty. `nix copy --to <path>` is used to seed
        the store, so nix reconstructs the `/nix` suffix itself.
      '';
    };

    # Host path bind-mounted into the container at `store.path`. The
    # relocated store lives at <hostBackup>/nix on the host.
    hostBackup = mkOption {
      type = types.str;
      default = "/srv/bincache";
      description = ''
        Host directory bind-mounted into the container at `store.path`
        (e.g. mounted at `/srv` for `store.path = "/srv"`). The relocated
        store materialises at `<hostBackup>/nix` on the host.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.store.path != "";
        message = "services.nixtache.runner.store.path is mandatory and must not be empty (use \"/\" for the native /nix store).";
      }
    ];

    # One container literal: the (optional) srv-nix mount + the custom
    # nix-daemon/storage machinery. Single use of the dynamic key
    # `${cfg.containerName}` (Nix forbids two path-assignments sharing a
    # dynamic prefix inside one literal).
    containers.${cfg.containerName} = {
      bindMounts = optionalAttrs customStore {
        "srv-nix" = {
          mountPoint = cfg.store.path;
          hostPath = cfg.store.hostBackup;
          isReadOnly = false;
        };
      };

      config = { config, lib, pkgs, ... }: {
      systemd.services = mkMerge [
        # One `gitea-runner-<name>` service per enabled instance gets the
        # relocated-store BindPaths + a hard dep on the custom daemon.
        (mapAttrs'
          (iname: _:
            nameValuePair "gitea-runner-${iname}" (mkIf customStore {
              after = [ "nix-daemon-custom.service" ];
              requires = [ "nix-daemon-custom.service" ];
              serviceConfig.BindPaths = [ bindPath ];
            }))
          enabledInstances)

        {
          # nix-serve also depends on the custom daemon + the bind. The
          # service itself is declared by cache.nix; this only amends it when
          # the store is relocated.
          nix-serve = mkIf (cfg.cache.enable && customStore) {
            after = [ "nix-daemon-custom.service" ];
            requires = [ "nix-daemon-custom.service" ];
            serviceConfig.BindPaths = [ bindPath ];
          };

          # Look on my Works, ye Mighty, and despair!
          # Custom nix-daemon bound to the relocated store. Only enabled
          # when the store is relocated (store.path != "/").
          nix-daemon-custom = mkIf customStore (
            let
              nixDaemonCfg = config.systemd.services.nix-daemon;
            in
            {
              description = lib.mkForce "Nix Daemon with custom /nix bind mount";

              wantedBy = lib.mkForce [ "multi-user.target" ];

              environment = lib.filterAttrs (n: _v: n != "PATH") nixDaemonCfg.environment;
              inherit (nixDaemonCfg) unitConfig;

              after = [ "nix-daemon-storage.service" ];
              requires = [ "nix-daemon-storage.service" ];

              serviceConfig = {
                ExecStart = "${config.nix.package}/bin/nix-daemon --daemon";
                KillMode = "process";
                BindPaths = [ bindPath ];
                CPUSchedulingPolicy = nixDaemonCfg.serviceConfig.CPUSchedulingPolicy;
                IOSchedulingClass = nixDaemonCfg.serviceConfig.IOSchedulingClass;
                IOSchedulingPriority = nixDaemonCfg.serviceConfig.IOSchedulingPriority;
                OOMScoreAdjust = "-999";
                OOMPolicy = "continue";
                Delegate = "yes";
                TasksMax = 1048576;
                LimitNOFILE = 1048576;
              };

              stopIfChanged = false;
            }
          );

          # Seeds the relocated store by copying the live /nix into
          # store.path. `nix copy --to <store.path>` reconstructs the /nix
          # suffix itself, producing <store.path>/nix.
          nix-daemon-storage = mkIf customStore {
            description = "copy entire nix store and rebind from new location";

            after = [
              "nix-daemon.service"
              "network.target"
            ];
            requires = [ "nix-daemon.service" ];

            serviceConfig = {
              Environment = [
                "USER=root"
                "NIX_REMOTE=daemon"
              ];

              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "setup-nix-backup" ''
                ${pkgs.coreutils}/bin/echo "Starting nix copy loop as root..."
                until ${pkgs.nix}/bin/nix copy --no-check-sigs --all --to ${cfg.store.path} > /var/log/nix-copy-setup.log 2>&1; do
                  ${pkgs.coreutils}/bin/echo "Copy failed (locked or RO), retrying in 5 seconds..."
                  ${pkgs.coreutils}/bin/sleep 5
                done
              '';
              User = "root";
              Group = "root";
              KillSignal = "SIGINT";
              SendSIGKILL = "no";
              Nice = 19;
              IOSchedulingClass = "idle";
              TimeoutStartSec = lib.mkForce "1d";
            };
            wantedBy = [ "multi-user.target" ];
          };
        }
      ];

      systemd.sockets.nix-daemon-custom = mkIf customStore {
        description = "Custom Nix Daemon Socket";
        listenStreams = [ "${cfg.store.path}/nix/var/nix/daemon-socket/socket" ];
        socketConfig.DirectoryMode = "0755";
        wantedBy = [ "sockets.target" ];
      };
      };
    };
  };
}

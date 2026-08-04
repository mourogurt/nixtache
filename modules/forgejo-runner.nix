# Forgejo Actions runner as a reusable, vendor-agnostic NixOS module.
#
# Lifted from nixos-configuration/server/services/forgejo-runner.nix and parameterised:
#   - all project-specific values are options (URL, cache domain/port, known hosts, limits);
#   - secrets are supplied by the consumer as `types.path` (Q4 path-based contract);
#   - the module does NOT declare sops.secrets nor hardcode hosts/domains.
#
# The module spins up a NixOS container `forgejo-runner` that:
#   - runs `gitea-actions-runner` (forgejo-runner) with a label `nixos:host`;
#   - keeps a nix store at `store.path` + "/nix". Set `store.path = "/"` to
#     reuse the container's system nix-daemon (native /nix); any other base
#     (e.g. "/srv") relocates the store and runs a custom nix-daemon +
#     storage oneshot, injecting a BindPaths bind onto /nix into the working
#     services (gitea-runner, nix-serve);
#   - serves a binary cache (nix-serve-ng) proxied by nginx.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.forgejo-runner;

  # Known-host entry type: a named SSH host key trusted inside the container.
  knownHostEntry = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Arbitrary key under services.openssh.knownHosts.";
      };
      hostNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Host names / IPs / aliases this key is valid for.";
      };
      publicKey = mkOption {
        type = types.str;
        description = "The SSH public key line.";
      };
    };
  };

  # Default GitHub known hosts (generic, reusable).
  defaultExtraKnownHosts = [
    {
      name = "github_rsa";
      hostNames = [ "github.com" ];
      publicKey =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q>";
    }
    {
      name = "github_ecdsa";
      hostNames = [ "github.com" ];
      publicKey =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    }
    {
      name = "github_ed25519";
      hostNames = [ "github.com" ];
      publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    }
  ];

  # Effective known-hosts list = primary git host (if set) + extras.
  knownHostEntries =
    (optional (cfg.gitHost != null) cfg.gitHost)
    ++ cfg.extraKnownHosts;

  knownHostsAttrset = listToAttrs (
    map (e: nameValuePair e.name { inherit (e) hostNames publicKey; }) knownHostEntries
  );

  # Host values that must propagate into the container (evaluated on the host).
  system_version = config.system.stateVersion;
  system_features = config.nix.settings.system-features;

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
  options.services.nixtache.forgejo-runner = {
    enable = mkEnableOption "Forgejo Actions runner in a NixOS container with a detached nix store and binary cache";

    # --- Forgejo connection -------------------------------------------------
    forgejoUrl = mkOption {
      type = types.str;
      example = "http://localhost:3000";
      description = ''
        URL of the Forgejo instance the runner registers against.
        Typically `http://localhost:<port>` when Forgejo runs on the same host.
      '';
    };

    # --- Runner identity & behaviour ---------------------------------------
    containerName = mkOption {
      type = types.str;
      default = "forgejo-runner";
      description = "Name of the NixOS container (and the `container@<name>` systemd unit).";
    };

    runnerName = mkOption {
      type = types.str;
      default = "nixos-container-runner";
      description = "Runner name as registered in Forgejo.";
    };

    labels = mkOption {
      type = types.listOf types.str;
      default = [ "nixos:host" ];
      description = "Runner labels.";
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

    # --- Binary cache -------------------------------------------------------
    cache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to run nix-serve-ng and expose it via nginx.";
      };

      domain = mkOption {
        type = types.str;
        example = "bincache.example.com";
        description = "Public domain for the binary cache nginx virtual host.";
      };

      port = mkOption {
        type = types.port;
        example = 7125;
        description = "Local port nix-serve-ng listens on (proxied by nginx).";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.nix-serve-ng;
        defaultText = lib.literalExpression "pkgs.nix-serve-ng";
        description = "nix-serve package to use.";
      };
    };

    # --- Detached nix store ------------------------------------------------
    store = {
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
        `experimental-features`, `trusted-users` and `system-features` on top
        of these. Include your binary cache (`substituters` +
        `trusted-public-keys`) here if you want the runner to consume it.
      '';
    };

    # --- SSH known hosts inside the container ------------------------------
    gitHost = mkOption {
      type = types.nullOr knownHostEntry;
      default = null;
      description = ''
        Primary Forgejo/git host the runner pushes back to. Provide all
        resolvable names (domain, apex, server IP, localhost) in `hostNames`
        so git operations succeed regardless of the URL form used.
      '';
    };

    extraKnownHosts = mkOption {
      type = types.listOf knownHostEntry;
      default = defaultExtraKnownHosts;
      defaultText = lib.literalMD "GitHub host keys";
      description = "Additional SSH known hosts (defaults to github.com keys).";
    };

    # --- Secrets (Q4: path-based, supplied by the consumer) ---------------
    secrets = {
      tokenFile = mkOption {
        type = types.path;
        description = ''
          File containing the runner registration token.
          Supplied by the consumer (sops / vault / systemd / ...).
        '';
      };

      sshPrivateKey = mkOption {
        type = types.path;
        description = "Bot SSH private key file (for pushing back to the git host).";
      };

      sshPublicKey = mkOption {
        type = types.path;
        description = "Bot SSH public key file matching `sshPrivateKey`.";
      };

      cachePrivateKey = mkOption {
        type = types.path;
        description = "Binary cache signing key file (used by nix-serve-ng).";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.store.path != "";
        message = "services.nixtache.forgejo-runner.store.path is mandatory and must not be empty (use \"/\" for the native /nix store).";
      }
    ];

    containers.${cfg.containerName} = {
      autoStart = true;

      bindMounts = {
        "forgejo-token" = {
          mountPoint = "/var/secrets/forgejo-runner/token";
          hostPath = cfg.secrets.tokenFile;
          isReadOnly = true;
        };
        "ssh-private-key" = {
          mountPoint = "/var/secrets/forgejo-runner/ssh_host_ed25519_key";
          hostPath = cfg.secrets.sshPrivateKey;
          isReadOnly = true;
        };
        "ssh-public-key" = {
          mountPoint = "/var/secrets/forgejo-runner/ssh_host_ed25519_key.pub";
          hostPath = cfg.secrets.sshPublicKey;
          isReadOnly = true;
        };
        "cache-private-key" = {
          mountPoint = "/var/secrets/forgejo-runner/cache-private-key.pem";
          hostPath = cfg.secrets.cachePrivateKey;
          isReadOnly = true;
        };
        "srv-nix" = mkIf customStore {
          mountPoint = cfg.store.path;
          hostPath = cfg.store.hostBackup;
          isReadOnly = false;
        };
      };

      # `system_version` / `system_features` are evaluated on the host and
      # propagated verbatim into the container.
      specialArgs = {
        inherit system_version system_features;
      };

      config =
        {
          config,
          lib,
          pkgs,
          system_version,
          system_features,
          ...
        }:
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
              }
            ];
          };

          services.gitea-actions-runner = {
            package = pkgs.forgejo-runner;
            instances.default = {
              enable = true;
              name = cfg.runnerName;

              url = cfg.forgejoUrl;

              tokenFile = "/var/secrets/forgejo-runner/token";

              labels = cfg.labels;

              settings = {
                runner = {
                  timeout = cfg.runnerTimeout;
                  shutdown_timeout = cfg.runnerTimeout;
                };
                log = {
                  level = cfg.logLevel;
                  job_level = cfg.logLevel;
                };
              };

              hostPackages = cfg.hostPackages;
            };
          };

          services = {
            openssh = {
              enable = false;
              knownHosts = knownHostsAttrset;
            };
            nix-serve = mkIf cfg.cache.enable {
              enable = true;
              secretKeyFile = "/var/secrets/forgejo-runner/cache-private-key.pem";
              package = cfg.cache.package;
              bindAddress = "localhost";
              port = cfg.cache.port;
            };
          };

          systemd.services = {
            # Working services: the relocated /nix bind + a hard dependency on
            # the custom daemon are injected only when the store is relocated
            # (store.path != "/"). When store.path == "/" these services run
            # unchanged against the container's system nix-daemon.
            gitea-runner-default = mkMerge [
              {
                serviceConfig.LoadCredential = [
                  "ssh_private:/var/secrets/forgejo-runner/ssh_host_ed25519_key"
                  "ssh_public:/var/secrets/forgejo-runner/ssh_host_ed25519_key.pub"
                ];
              }
              (mkIf customStore {
                after = [ "nix-daemon-custom.service" ];
                requires = [ "nix-daemon-custom.service" ];
                serviceConfig.BindPaths = [ bindPath ];
              })
            ];

            nix-serve = mkIf (cfg.cache.enable && customStore) {
              after = [ "nix-daemon-custom.service" ];
              requires = [ "nix-daemon-custom.service" ];
              serviceConfig.BindPaths = [ bindPath ];
            };

            # Look on my Works, ye Mighty, and despair!
            # Custom nix-daemon bound to the relocated store. Only enabled when
            # the store is relocated (store.path != "/").
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
          };

          systemd.sockets.nix-daemon-custom = mkIf customStore {
            description = "Custom Nix Daemon Socket";
            listenStreams = [ "${cfg.store.path}/nix/var/nix/daemon-socket/socket" ];
            socketConfig.DirectoryMode = "0755";
            wantedBy = [ "sockets.target" ];
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

    # Public binary cache vhost (host side). Requires nginx to be configured
    # on the host; the module only adds the virtual host.
    services.nginx = mkIf cfg.cache.enable {
      virtualHosts.${cfg.cache.domain} = {
        enableACME = true;
        forceSSL = true;
        locations."/".proxyPass = "http://localhost:${toString cfg.cache.port}";
      };
    };
  };
}

# Forgejo/Gitea Actions runner as a reusable, vendor-agnostic NixOS module.
#
# Lifted from nixos-configuration/server/services/forgejo-runner.nix and parameterised:
#   - all project-specific values are options (URL, cache domain/port, known hosts, limits);
#   - secrets are supplied by the consumer as `types.path` (Q4 path-based contract);
#   - the module does NOT declare sops.secrets nor hardcode hosts/domains.
#
# The module spins up a NixOS container `runner` that:
#   - runs one or more `gitea-actions-runner` (forgejo-runner) instances, each
#     with its own name/labels, all registering against the same Forgejo/Gitea URL
#     (e.g. a `default` runner on `nixos:host` and a `test` runner on
#     `nixos:test` for CI experiments);
#   - exports `gitUser` to every job via `runner.envs.NIXTACHE_GIT_USER` so the
#     CI (ssh-setup, push steps) use the consumer's git SSH user instead of a
#     hardcoded `forgejo@`/`git@`;
#   - keeps a nix store at `store.path` + "/nix". Set `store.path = "/"` to
#     reuse the container's system nix-daemon (native /nix); any other base
#     (e.g. "/srv") relocates the store and runs a custom nix-daemon +
#     storage oneshot, injecting a BindPaths bind onto /nix into every
#     runner service + nix-serve;
#   - serves a binary cache (nix-serve-ng) proxied by nginx.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;

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

  # A single runner instance. All instances share the container's relocated
  # nix store, SSH/bot keys, cache and Forgejo URL; they differ by `name`,
  # `labels` and `tokenFile` (one registration token per instance) so Forgejo
  # can route jobs to a specific runner (e.g. a "test" runner on a distinct
  # label with its own token).
  instanceType = types.submodule ({ name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this runner instance.";
      };
      name = mkOption {
        type = types.str;
        default = name;
        description = "Runner name as registered in Forgejo (defaults to the instance attribute name).";
      };
      labels = mkOption {
        type = types.listOf types.str;
        default = [ "nixos:host" ];
        description = "Runner labels (Forgejo routes jobs to instances by label).";
      };
      tokenFile = mkOption {
        type = types.path;
        description = ''
          Environment file (a systemd `EnvironmentFile`) containing the
          `TOKEN` variable used to register THIS instance. One token per
          instance — Forgejo issues a registration token per runner.
          Supplied by the consumer (sops / vault / systemd / ...).
        '';
      };
    };
  });

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

  # Enabled runner instances. Each becomes a `gitea-runner-<name>` service and
  # receives the relocated-store BindPaths + nix-daemon-custom dependency.
  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;

  # SSH credentials for a single purpose: a user (server RUN_USER) + key pair.
  # Two independent bundles exist — one for fetching private flake inputs
  # (`flakeSshCreds`, used by nix-check's `nix flake check`), one for the
  # update-flake workflow (`updateSshCreds`, push + commit signing). They mount
  # as separate LoadCredentials (flake_ssh_* / update_ssh_*); typically the
  # consumer points both at the same key files.
  sshCredsType = types.submodule {
    options = {
      user = mkOption {
        type = types.str;
        description = "SSH user (server `RUN_USER`, e.g. `forgejo`/`git`) for this credential.";
      };
      sshPrivateKey = mkOption {
        type = types.path;
        description = "Bot SSH private key file path.";
      };
      sshPublicKey = mkOption {
        type = types.path;
        description = "Bot SSH public key file path matching `sshPrivateKey`.";
      };
    };
  };

  flakeSsh = cfg.flakeSshCreds;
  updateSsh = cfg.updateSshCreds;
  flakeSshEnabled = flakeSsh != null;
  updateSshEnabled = updateSsh != null;
  anySsh = flakeSshEnabled || updateSshEnabled;
in
{
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

    # SSH credentials for fetching PRIVATE flake inputs (e.g. nixos-private)
    # during `nix flake check`. Optional: omit for public-input-only setups.
    # Exported to jobs as NIXTACHE_FLAKE_GIT_USER + a `flake_ssh_*`
    # LoadCredential that the ssh-setup action (creds: flake) reads.
    flakeSshCreds = mkOption {
      type = types.nullOr sshCredsType;
      default = null;
      description = ''
        SSH credentials for fetching private flake inputs in CI. When set,
        `nix flake check` / `nix flake metadata` can git+ssh-clone private
        inputs (e.g. `nixos-private`). null = no private-input auth (public
        inputs only).
      '';
    };

    # SSH credentials for the update-flake workflow (push lock-file commits +
    # sign them). Optional: when null, update-flake self-disables with a
    # warning. Exported as NIXTACHE_UPDATE_GIT_USER + `update_ssh_*`
    # LoadCredential (ssh-setup creds: update). Typically the same key files as
    # `flakeSshCreds`.
    updateSshCreds = mkOption {
      type = types.nullOr sshCredsType;
      default = null;
      description = ''
        SSH credentials for the update-flake workflow (push + commit signing).
        null = update-flake is disabled (its workflow detects the missing
        credential and no-ops with a warning). Typically points at the same
        key files as `flakeSshCreds`.
      '';
    };

    # Bot identity (Forgejo account) that owns CI-generated commits. Its KEY is
    # `updateSshCreds`; `name`/`email` are the commit author. Exported to jobs
    # as NIXTACHE_BOT_NAME / NIXTACHE_BOT_EMAIL.
    bot = {
      name = mkOption {
        type = types.str;
        default = "fbot";
        description = "Bot account name (commit `user.name`) for CI-generated commits.";
      };
      email = mkOption {
        type = types.str;
        default = "fbot@localhost";
        description = "Bot account email (commit `user.email`) for CI-generated commits.";
      };
    };

    # Runner instances. Each registers as a separate runner on `forgejoUrl`
    # with its own name/labels/tokenFile; all share the container's store,
    # (optional) SSH/bot keys, cache and nix settings. Add a second instance
    # (e.g. `test`) to get a dedicated runner for CI experiments routed by label.
    instances = mkOption {
      type = types.attrsOf instanceType;
      description = ''
        Runner instances to start inside the container. Each becomes a
        `gitea-runner-<name>` service and needs its own `tokenFile`
        (a Forgejo registration token). Example:

        ```
        instances = {
          default = { tokenFile = config.sops.secrets.runner-token-default.path; };
          test    = { labels = [ "nixos:test" ]; tokenFile = config.sops.secrets.runner-token-test.path; };
        };
        ```
      '';
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
    # NOTE: the registration token is per-instance (`instances.<name>.tokenFile`),
    # not global. SSH creds live in `flakeSshCreds` / `updateSshCreds`.
    secrets = {
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
        message = "services.nixtache.runner.store.path is mandatory and must not be empty (use \"/\" for the native /nix store).";
      }
    ];

    containers.${cfg.containerName} = {
      autoStart = true;

      # Per-instance token mounts + shared key/cache mounts. The relocated-store
      # mount and the (optional) SSH key mounts are added conditionally below.
      bindMounts = mkMerge [
        (listToAttrs (mapAttrsToList
          (iname: i:
            nameValuePair "runner-token-${iname}" {
              mountPoint = "/var/secrets/runner/${iname}/token";
              hostPath = i.tokenFile;
              isReadOnly = true;
            })
          enabledInstances))
        (optionalAttrs flakeSshEnabled {
          "flake-ssh-private-key" = {
            mountPoint = "/var/secrets/runner/flake_ssh_key";
            hostPath = flakeSsh.sshPrivateKey;
            isReadOnly = true;
          };
          "flake-ssh-public-key" = {
            mountPoint = "/var/secrets/runner/flake_ssh_key.pub";
            hostPath = flakeSsh.sshPublicKey;
            isReadOnly = true;
          };
        })
        (optionalAttrs updateSshEnabled {
          "update-ssh-private-key" = {
            mountPoint = "/var/secrets/runner/update_ssh_key";
            hostPath = updateSsh.sshPrivateKey;
            isReadOnly = true;
          };
          "update-ssh-public-key" = {
            mountPoint = "/var/secrets/runner/update_ssh_key.pub";
            hostPath = updateSsh.sshPublicKey;
            isReadOnly = true;
          };
        })
        {
          "cache-private-key" = {
            mountPoint = "/var/secrets/runner/cache-private-key.pem";
            hostPath = cfg.secrets.cachePrivateKey;
            isReadOnly = true;
          };
          "srv-nix" = mkIf customStore {
            mountPoint = cfg.store.path;
            hostPath = cfg.store.hostBackup;
            isReadOnly = false;
          };
        }
      ];

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
            package = cfg.package;
            # One instance per enabled entry; all share forgejoUrl, host packages,
            # timeouts and log level. Each gets its own token mount + registration.
            instances = mapAttrs (iname: i: {
              enable = true;
              name = i.name;
              url = cfg.forgejoUrl;
              tokenFile = "/var/secrets/runner/${iname}/token";
              labels = i.labels;
              settings = {
                runner = {
                  timeout = cfg.runnerTimeout;
                  shutdown_timeout = cfg.runnerTimeout;
                  # Export the consumer's git SSH user + bot identity to every
                  # job step (act_runner `runner.envs` — mode-agnostic, applies
                  # to host mode too). Read by ssh-setup / push / commit steps
                  # to avoid hardcoding forgejo@/git@ and the bot name/email.
                  # Export SSH users + bot identity to every job step (act_runner
                  # `runner.envs` — mode-agnostic, applies to host mode too).
                  # `ssh-setup` picks the right pair via its `creds` input.
                  envs = {
                    NIXTACHE_FLAKE_GIT_USER = lib.optionalString flakeSshEnabled flakeSsh.user;
                    NIXTACHE_UPDATE_GIT_USER = lib.optionalString updateSshEnabled updateSsh.user;
                    NIXTACHE_BOT_NAME = cfg.bot.name;
                    NIXTACHE_BOT_EMAIL = cfg.bot.email;
                  };
                };
                log = {
                  level = cfg.logLevel;
                  job_level = cfg.logLevel;
                };
              };
              hostPackages = cfg.hostPackages;
            }) enabledInstances;
          };

          services = {
            openssh = {
              enable = false;
              knownHosts = knownHostsAttrset;
            };
            nix-serve = mkIf cfg.cache.enable {
              enable = true;
              secretKeyFile = "/var/secrets/runner/cache-private-key.pem";
              package = cfg.cache.package;
              bindAddress = "localhost";
              port = cfg.cache.port;
            };
          };

          systemd.services = mkMerge [
            # One `gitea-runner-<name>` service per enabled instance. Each gets
            # the bot SSH credentials and, when the store is relocated
            # (store.path != "/"), a BindPaths bind onto /nix + a hard dep on
            # the custom daemon. When store.path == "/" they run unchanged
            # against the container's system nix-daemon.
            (mapAttrs'
              (iname: _:
                nameValuePair "gitea-runner-${iname}" (mkMerge [
                  # SSH credentials are loaded per purpose (flake / update),
                  # each only when its bundle is configured. ssh-setup selects
                  # via its `creds` input → $CREDENTIALS_DIRECTORY/<creds>_ssh_*.
                  (mkIf anySsh {
                    serviceConfig.LoadCredential =
                      (optional flakeSshEnabled "flake_ssh_private:/var/secrets/runner/flake_ssh_key")
                      ++ (optional flakeSshEnabled "flake_ssh_public:/var/secrets/runner/flake_ssh_key.pub")
                      ++ (optional updateSshEnabled "update_ssh_private:/var/secrets/runner/update_ssh_key")
                      ++ (optional updateSshEnabled "update_ssh_public:/var/secrets/runner/update_ssh_key.pub");
                  })
                  (mkIf customStore {
                    after = [ "nix-daemon-custom.service" ];
                    requires = [ "nix-daemon-custom.service" ];
                    serviceConfig.BindPaths = [ bindPath ];
                  })
                ]))
              enabledInstances)

            {
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

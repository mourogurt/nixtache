# Detached nix store for the runner container.
#
# Owns `store.path` / `store.hostBackup` / `store.mode` and the entire
# relocated-store machinery: when `store.path != "/"` the store lives at
# `<path>/nix` and a custom `nix-daemon` + storage oneshot + socket run inside
# the container, with a `BindPaths` bind onto /nix injected into every
# `gitea-runner-*` service and `nix-serve`. When `store.path == "/"` the
# container reuses its system nix-daemon and this module contributes nothing.
#
# `store.mode` selects how the relocated store is populated:
#   - `clone`  (default): `nix copy --all` into `<path>/nix` (full writable copy).
#   - `overlay`: OverlayFS mount (lower=/nix/store ro, upper=<path>/overlay/upper)
#               served as a `local-overlay://` store — instant (no copy), proper
#               GC, but requires Nix ≥ 2.19 + CAP_SYS_ADMIN on the container.
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

  # Appliance mode: the HOST has nix disabled (an A/B appliance image). The
  # container then runs with its own nix module disabled (the container's
  # nix-daemon cannot exist — its socket dir is a read-only host bind), the
  # module renders nix.conf directly, and the standalone branches below
  # activate (clone: no nix-daemon.service requirement, scratch-DB copy of the
  # host's real DB; overlay: lower-store=local).
  hostNixDisabled = !config.nix.enable;

  # In overlay mode the writable layer is an OverlayFS mount instead of a full
  # `nix copy --all` clone. Both modes share the same container wiring (bind
  # mount, BindPaths, custom daemon socket); only the SEEDING mechanism + the
  # daemon's store URL differ.
  useOverlay = customStore && cfg.store.mode == "overlay";
  useClone = customStore && cfg.store.mode == "clone";

  # systemd BindPaths spec that re-exposes the relocated store (<path>/nix)
  # at /nix. nix itself reconstructs the /nix suffix for `nix copy --to <path>`.
  bindPath = "${cfg.store.path}/nix:/nix";

  # local-overlay store URL the custom daemon serves in overlay mode. The
  # lower-store provider depends on the host:
  #   - nix-enabled host: `lower-store=daemon` — the container's system
  #     nix-daemon (reading the container's ro /nix/store bind) provides the
  #     lower layer's validity.
  #   - appliance host (nix disabled): `lower-store=local` — the RO-bound host
  #     DB is real (the slot image ships it) and opens read-only. `daemon`
  #     would self-reference here (no system daemon exists inside the
  #     container): the custom daemon's workers reconnect to their own socket
  #     and fork-loop.
  # Writes land in the upper layer; GC reaps upper paths and ignores delete
  # failures on the read-only lower.
  overlayStoreUrl = "local-overlay://"
    + "?root=${cfg.store.path}"
    + "&lower-store=${if hostNixDisabled then "local" else "daemon"}"
    + "&upper-layer=${cfg.store.path}/overlay/upper"
    + "&ignore-gc-delete-failure=true";
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

    mode = mkOption {
      type = types.enum [ "clone" "overlay" ];
      default = "clone";
      description = ''
        How the relocated store is populated inside the container:

        `clone` (default): `nix copy --all` creates a full writable copy at
        `<store.path>/nix`. Slow (multi-GB), but works on any Nix version. The
        clone is additive across reboots (new paths added, old kept).

        `overlay`: an OverlayFS mount combines the read-only lower store
        (`/nix/store`) with a writable upper (`<store.path>/overlay/upper`),
        served as a `local-overlay://` store. Instant (no copy), proper GC
        (upper-layer paths reaped, lower untouched), but requires Nix ≥ 2.19
        (the `local-overlay-store` experimental feature) AND `CAP_SYS_ADMIN`
        on the container (set `additionalCapabilities = ["CAP_SYS_ADMIN"]` and
        `enableSandbox = false`) so the overlay mount can happen inside nspawn.

        Doc: https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.store.path != "";
        message = "services.nixtache.runner.store.path is mandatory and must not be empty (use \"/\" for the native /nix store).";
      }
      {
        assertion = cfg.store.path != "/" || !(config.services.nixtache.ab-image.enable or false);
        message = ''
          services.nixtache.runner.store.path = "/" is incompatible with
          services.nixtache.ab-image.enable = true. The host's /nix/store is
          read-only squashFS/erofs on A/B appliances — the container's system
          nix-daemon cannot write CI build outputs. Set store.path to a
          persistent location on the root FS (e.g. "/srv") — the runner
          clones the store there and serves a writable copy via
          nix-daemon-custom.
        '';
      }
      {
        assertion = !useOverlay
          || (builtins.compareVersions config.nix.package.version "2.19") >= 0;
        message = ''
          services.nixtache.runner.store.mode = "overlay" requires Nix >= 2.19
          (experimental feature `local-overlay-store`; present since 2.19, NOT
          2.35 — the nix.dev /2.35/ doc URL is misleading). Current:
          ${config.nix.package.version}.
        '';
      }
    ];

    # One container literal: the (optional) srv-nix mount + the custom
    # nix-daemon/storage machinery. Single use of the dynamic key
    # `${cfg.containerName}` (Nix forbids two path-assignments sharing a
    # dynamic prefix inside one literal).
    #
    # The host backup dir must exist before the container starts — systemd-
    # nspawn refuses to bind-mount a missing hostPath. Create it declaratively.
    systemd.tmpfiles.rules = mkMerge [      (mkIf customStore [
        "d ${cfg.store.hostBackup} 0755 root root -"
      ])
      # nixpkgs' container start unconditionally bind-ros the host's
      # /nix/var/nix/db + /nix/var/nix/daemon-socket into the container
      # (nixos-containers.nix). On an appliance host (nix.enable=false, e.g.
      # an A/B image) those paths don't exist and the container fails to
      # start ("Failed to clone ...: No such file or directory"). Guarantee
      # them — empty dirs at first; the slot's boot loader then fills the
      # host DB from the shipped lower-store dump, and the container's
      # appliance-mode wiring consults it (clone enumerates it via a scratch
      # copy; overlay reads it as the local lower).
      (mkIf (!config.nix.enable) [
        "d /nix/var/nix/db 0755 root root -"
        "d /nix/var/nix/daemon-socket 0755 root root -"
      ])
    ];

    # On an A/B appliance host, the slot's lower-DB loader must merge the
    # running slot's records before the container's store machinery reads the
    # host DB (clone: the seed enumerates it; overlay: the local lower opens
    # it) — an unordered start could copy/open only the pre-swap records and
    # silently miss the new slot's content. Ordering only (no requirement):
    # the loader is ConditionPathExists-guarded and legitimately skips when
    # no dump arrived.
    systemd.services."container@${cfg.containerName}" =
      mkIf (config.services.nixtache.ab-image.enable or false) {
        after = [ "nixtache-lower-store-db-load.service" ];
      };

    containers.${cfg.containerName} = {
      bindMounts = optionalAttrs customStore {
        "srv-nix" = {
          mountPoint = cfg.store.path;
          hostPath = cfg.store.hostBackup;
          isReadOnly = false;
        };
      };

      config = { config, lib, pkgs, ... }: {
      # Appliance mode (host nix.enable=false): the container runs with its
      # own nix module disabled — a system nix-daemon cannot exist inside it
      # (the daemon-socket dir is a read-only host bind, so no socket can be
      # created) and the nix module's assertions tie gc/optimise to nix.enable.
      # The store machinery below then takes its standalone branches. nix.conf
      # is rendered directly (the nix module no longer writes it) with the same
      # settings content, so CI keeps system-features/substituters/trusted-users;
      # the nix CLI ships explicitly for the custom daemon + CI jobs.
      nix = mkIf hostNixDisabled {
        enable = false;
        # mkForce: the base container config (default.nix) sets both to true
        # at normal priority; nixpkgs asserts they require nix.enable.
        gc.automatic = lib.mkForce false;
        optimise.automatic = lib.mkForce false;
      };
      environment = mkIf hostNixDisabled {
        etc."nix/nix.conf".source = (pkgs.formats.nixConf {
          inherit (config.nix) package extraOptions checkAllErrors checkConfig;
          inherit (config.nix.package) version;
        }).generate "nix.conf" config.nix.settings;
        systemPackages = [ config.nix.package ];
      };

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
          # when the store is relocated (store.path != "/"). In clone mode it
          # requires `nix-daemon-storage` (the seeder) and serves a plain local
          # store; in overlay mode it requires `nix-daemon-overlay-mount` and
          # serves a `local-overlay://` store over the merged OverlayFS view.
          nix-daemon-custom = mkIf customStore (
            let
              # Absent when the container disables nix (appliance-style
              # containers, nix.enable=false) — the custom daemon then runs
              # standalone with nix defaults instead of the system daemon's.
              nixDaemonCfg = config.systemd.services.nix-daemon or { };
              # In overlay mode the daemon talks to a local-overlay store rooted
              # at <store.path>; in clone mode it serves the plain relocated
              # local store at <store.path>/nix.
               seedUnit = if useOverlay then "nix-daemon-overlay-mount.service" else "nix-daemon-storage.service";
              # nix.conf content for the custom daemon (NIX_CONF env — a
              # multi-line nix.conf read as an alt to /etc/nix/nix.conf):
              # - overlay mode opts into the local-overlay-store experimental
              #   feature;
              # - the daemon realizes the fleet's content-addressed closure,
              #   so `ca-derivations` is always on here;
              # - on appliance-style containers (nix.enable=false) no nixbld
              #   build users exist, so the daemon builds as root.
              nixConf = lib.concatStringsSep "\n" (
                [ "extra-experimental-features = ca-derivations" ]
                ++ lib.optional useOverlay "extra-experimental-features = local-overlay-store"
                ++ lib.optional (!config.nix.enable) "build-users-group ="
              );
            in
            {
              description = lib.mkForce "Nix Daemon with custom /nix bind mount";

              wantedBy = lib.mkForce [ "multi-user.target" ];

              unitConfig = nixDaemonCfg.unitConfig or { };

              environment = (lib.filterAttrs (n: _v: n != "PATH") (nixDaemonCfg.environment or { }))
                // (lib.optionalAttrs (nixConf != "") {
                  NIX_CONF = nixConf;
                });

              after = [ seedUnit ];
              requires = [ seedUnit ];

              serviceConfig = {
                # enableSandbox: the daemon's exec chain first replaces the
                # nspawn-masked /proc (its locked ro submounts make nix's
                # sandbox preflight fail with EPERM on the child-userns proc
                # overmount). unshare -m + mount + exec in ONE chain, because
                # systemd clones the mount namespace per Exec* command — an
                # ExecStartPre mount would never reach the daemon. Full
                # mechanism: doc/technical_details/sandboxing.md.
                ExecStart =
                  let
                    daemonCmd = if useOverlay
                      then "${config.nix.package}/bin/nix-daemon --store '${overlayStoreUrl}'"
                      else "${config.nix.package}/bin/nix-daemon --daemon";
                  in
                  if cfg.enableSandbox
                  then "${lib.getExe' pkgs.util-linux "unshare"} -m ${pkgs.writeShellScript "nix-daemon-custom-fresh-proc" ''
                    ${lib.getExe' pkgs.util-linux "mount"} proc -t proc /proc
                    exec -a nix-daemon ${daemonCmd}
                  ''}"
                  else daemonCmd;
                KillMode = "process";
                BindPaths = [ bindPath ];
                CPUSchedulingPolicy = nixDaemonCfg.serviceConfig.CPUSchedulingPolicy or null;
                IOSchedulingClass = nixDaemonCfg.serviceConfig.IOSchedulingClass or null;
                IOSchedulingPriority = nixDaemonCfg.serviceConfig.IOSchedulingPriority or null;
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
          # suffix itself, producing <store.path>/nix. CLONE MODE ONLY —
          # overlay mode replaces this with nix-daemon-overlay-mount.
          nix-daemon-storage = mkIf useClone {
            description = "copy entire nix store and rebind from new location";

            # The system nix-daemon only exists when the container's own nix is
            # enabled. On an A/B appliance container (nix.enable=false, no
            # overlay) there is no system daemon to require or copy through:
            # clone from the local store directly instead.
            after = lib.optional config.nix.enable "nix-daemon.service" ++ [
              "network.target"
            ];
            requires = lib.optional config.nix.enable "nix-daemon.service";

            serviceConfig = {
              Environment = [ "USER=root" ]
                ++ lib.optional config.nix.enable "NIX_REMOTE=daemon";

              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "setup-nix-backup" ''
                set -o pipefail
                ${lib.optionalString (!config.nix.enable) ''
                  # Standalone clone (no system daemon to copy through). Two
                  # read-only obstacles, two mechanisms:
                  #   - the local store's DB is a read-only host bind, which
                  #     sqlite cannot open → seed a writable scratch copy and
                  #     read through an explicit local-store URL (NOT
                  #     NIX_STATE_DIR — that would also redirect the
                  #     DESTINATION's DB);
                  #   - opening the source store runs the store-dir init and
                  #     a writable-remount attempt — both fail on the RO host
                  #     bind → `read-only=true` (the read-only-local-store
                  #     experimental feature) skips the remount, and the
                  #     createDirs calls succeed because the slot image ships
                  #     /nix/store/.links (see ab-image).
                  ${pkgs.coreutils}/bin/mkdir -p /run/nix-clone-state
                  ${pkgs.coreutils}/bin/cp -a /nix/var/nix/db /run/nix-clone-state/db
                  ${pkgs.coreutils}/bin/echo "clone seed: scratch DB holds $(${pkgs.nix}/bin/nix-store --store 'local?root=/&state=/run/nix-clone-state&read-only=true' --extra-experimental-features read-only-local-store -q --valid-paths | ${pkgs.coreutils}/bin/wc -l) valid paths"
                ''}
                ${pkgs.coreutils}/bin/echo "Starting nix copy loop as root..."
                # tee: progress (and any recurring failure) lands in the unit
                # journal — a silent multi-minute copy and an infinite retry
                # loop are indistinguishable without it. The log file stays
                # for post-mortem. pipefail (set above) keeps the loop
                # condition on nix's exit code, not tee's.
                until ${pkgs.nix}/bin/nix ${lib.optionalString (!config.nix.enable) "--extra-experimental-features 'nix-command read-only-local-store'"} copy --no-check-sigs --all ${lib.optionalString (!config.nix.enable) "--from 'local?root=/&state=/run/nix-clone-state&read-only=true'"} --to ${cfg.store.path} 2>&1 | ${pkgs.coreutils}/bin/tee /var/log/nix-copy-setup.log; do
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

          # OVERLAY MODE: mounts an OverlayFS at <store.path>/nix/store so the
          # custom daemon can serve a local-overlay store. lower=/nix/store
          # (the container's read-only bind of the host store), upper=<store
          # .path>/overlay/upper (writable, persistent), work=<store.path>
          # /overlay/work (OverlayFS kernel metadata). Replaces nix-daemon-
          # storage — no `nix copy --all`, instant COW.
          nix-daemon-overlay-mount = mkIf useOverlay {
            description = "Mount OverlayFS for the relocated nix store (local-overlay-store)";
            wantedBy = [ "multi-user.target" ];
            before = [ "nix-daemon-custom.service" ];
            path = with pkgs; [ util-linux coreutils ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "mount-nix-overlay" ''
                mkdir -p ${cfg.store.path}/nix/var/nix/daemon-socket
                mkdir -p ${cfg.store.path}/overlay/upper
                mkdir -p ${cfg.store.path}/overlay/work
                mkdir -p ${cfg.store.path}/nix/store
                mkdir -p ${cfg.store.path}/nix/var/nix/db
                if mountpoint -q ${cfg.store.path}/nix/store 2>/dev/null; then
                  echo "overlay already mounted at ${cfg.store.path}/nix/store"
                  exit 0
                fi
                mount -t overlay overlay \
                  -o lowerdir=/nix/store \
                  -o upperdir=${cfg.store.path}/overlay/upper \
                  -o workdir=${cfg.store.path}/overlay/work \
                  ${cfg.store.path}/nix/store
              '';
              ExecStop = pkgs.writeShellScript "umount-nix-overlay" ''
                umount ${cfg.store.path}/nix/store 2>/dev/null || true
              '';
            };
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

{ config
, lib
, pkgs
, cfg
, abEnabled
, lowerStateLink
, prepareScript
, selectionScript
, ...
}:

with lib;

let
  topology = cfg._topology;
  runnerLayers = filter (node: node ? containerName) topology.nodes;

  overlayStoreUrl = "local-overlay://"
    + "?lower-store=${if abEnabled then "local%3Fstate%3D${lowerStateLink}%26read-only%3Dtrue" else "local"}"
    + "&upper-layer=${cfg.upperDir}"
    + "&ignore-gc-delete-failure=true"
    + "&remount-hook=${remountHook}"
    + "&check-mount=false";

  remountHook = pkgs.writeShellScript "nixtache-overlay-remount" ''
    export PATH=${lib.makeBinPath [ pkgs.util-linux pkgs.coreutils ]}
    mountpoint="''${1:-/nix/store}"
    i=0
    while ! umount "$mountpoint"; do
      i=$((i + 1))
      if [ "$i" -ge 10 ]; then
        echo "nixtache-overlay-remount: $mountpoint still busy after 10 tries" >&2
        exit 0
      fi
      sleep 1
    done
    mount -t overlay overlay -o lowerdir="$mountpoint" -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} "$mountpoint"
  '';
in
{
  config = mkIf cfg.enable (mkMerge [
    {
      nix.enable = mkOverride 99 true;
      nix.settings.store = overlayStoreUrl;
      nix.settings.extra-experimental-features = [ "nix-command" "flakes" "local-overlay-store" "ca-derivations" "read-only-local-store" ];
      nix.settings.flake-registry = "";

      systemd.services.nixtache-overlay-select = {
        description = "Select and recover the physical slot's Nix upper metaslot";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "zfs-mount.service" ];
        before = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" "nix-daemon.service" ];
        path = with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd nix sqlite ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = readFile selectionScript;
      };

      systemd.services.nixtache-overlay-prepare = {
        description = "Prepare the inactive physical slot's Nix upper metaslot";
        path = with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd nix sqlite ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "1h";
        };
        script = "${prepareScript} --installed";
      };

      systemd.services.nix-daemon-overlay-mount = {
        description = "Mount the selected upper over the physical lower Nix store";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "nixtache-overlay-select.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        requires = [ "nixtache-overlay-select.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        before = [ "nix-daemon.service" ];
        path = with pkgs; [ util-linux coreutils gnugrep ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=${cfg.upperDir}'; then
            exit 0
          fi
          mount -t overlay overlay -o lowerdir=/nix/store -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} /nix/store
        '';
      };

      systemd.services.nix-daemon = {
        after = [ "nix-daemon-overlay-mount.service" "nixtache-overlay-ready.target" ];
        requires = [ "nix-daemon-overlay-mount.service" "nixtache-overlay-ready.target" ];
      };

      systemd.targets.nixtache-overlay-ready = {
        description = "Selected lower, upper files and Nix metadata are coherent";
        wantedBy = [ "multi-user.target" ];
        after = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        requires = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
      };

      systemd.targets.boot-complete = mkIf abEnabled {
        after = [ "nixtache-overlay-ready.target" ];
        requires = [ "nixtache-overlay-ready.target" ];
      };
    }

    (mkIf abEnabled {
      environment.etc."image-version".text = mkDefault config.system.image.version;
      systemd.services.nixtache-lower-store-db-load = {
        after = [ "nixtache-overlay-select.service" ];
        requires = [ "nixtache-overlay-select.service" ];
        before = [ "nix-daemon-overlay-mount.service" "nix-daemon.service" ];
      };
      systemd.services.systemd-sysupdate-reboot = {
        after = [ "nixtache-overlay-prepare.service" ];
        requires = [ "nixtache-overlay-prepare.service" ];
      };
    })

    (mkIf (runnerLayers != [ ]) {
      systemd.services = listToAttrs (map (node:
        nameValuePair "container@${node.containerName}" {
          after = [ "nixtache-overlay-ready.target" ];
          requires = [ "nixtache-overlay-ready.target" ];
        }
      ) runnerLayers);
    })
  ]);
}

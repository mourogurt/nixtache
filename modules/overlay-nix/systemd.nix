{ config
, lib
, pkgs
, cfg
, abEnabled
, runtimeState
, lowerStateLink
, slotsDir
, prepareScript
, selectionScript
, parentRootActivationSnippet
, ...
}:

with lib;

let
  topology = cfg._topology;
  runnerLayers = filter (node: node ? containerName) topology.nodes;
  frozenMounts = optionals abEnabled topology.frozenMounts;
  inherit (topology) parentRoot physicalHostRoot;
  hostRoot = parentRoot "host";
  frozenMountUnit = "nixtache-overlay-frozen.service";
  legacyFrozenRows = pkgs.writeText "nixtache-overlay-legacy-frozen.rows"
    (concatMapStrings (mount:
      "${mount.id}|${mount.logicalId}|frozen-lower|${if mount.parent == null then "-" else mount.parent}\n"
    ) frozenMounts);
  hostRuntimeLower = if abEnabled then "${hostRoot}/nix/store" else "/nix/store";
  encodeStoreUri = value: replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ] value;
  hostLowerStore = if abEnabled
    then "local?root=${hostRoot}&state=${hostRoot}/nix/var/nix&read-only=true"
    else "local";

  overlayStoreUrl = "local-overlay://"
    + "?lower-store=${encodeStoreUri hostLowerStore}"
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
    mount -t overlay overlay -o lowerdir=${hostRuntimeLower} -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} "$mountpoint"
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
        before = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" "nix-daemon.service" ]
          ++ optional abEnabled frozenMountUnit;
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
          TimeoutStartSec = "1h";
        };
        script = "${prepareScript} --installed";
      };

      systemd.services.nix-daemon-overlay-mount = {
        description = "Mount the selected upper over the physical lower Nix store";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "nixtache-overlay-select.service" ]
          ++ optionals abEnabled [ "nixtache-lower-store-db-load.service" frozenMountUnit ];
        requires = [ "nixtache-overlay-select.service" ]
          ++ optionals abEnabled [ "nixtache-lower-store-db-load.service" frozenMountUnit ];
        before = [ "nix-daemon.service" ];
        path = with pkgs; [ util-linux coreutils gnugrep ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if mount | grep 'overlay on /nix/store ' | grep 'lowerdir=${hostRuntimeLower}' | grep -q 'upperdir=${cfg.upperDir}'; then
            exit 0
          fi
          mount -t overlay overlay -o lowerdir=${hostRuntimeLower} -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} /nix/store
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
          ++ optionals abEnabled [ "nixtache-lower-store-db-load.service" frozenMountUnit ];
        requires = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optionals abEnabled [ "nixtache-lower-store-db-load.service" frozenMountUnit ];
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

    (mkIf abEnabled {
      systemd.services.nixtache-overlay-frozen = {
        description = "Mount every selected frozen Nix store read-only in plan order";
        wantedBy = [ "nixtache-overlay-ready.target" ];
        before = [ "nixtache-overlay-ready.target" "nix-daemon-overlay-mount.service" ];
        after = [ "nixtache-overlay-select.service" ];
        requires = [ "nixtache-overlay-select.service" ];
        path = with pkgs; [ coreutils gnugrep util-linux ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          slot=$(cat ${runtimeState}/selected-slot 2>/dev/null || true)
          generation=$(cat ${runtimeState}/selected-generation 2>/dev/null || true)
          if [ -n "$slot" ] || [ -n "$generation" ]; then
            [ -n "$slot" ] && [ -n "$generation" ]
            [ "$(readlink -f "${slotsDir}/$slot/current")" = "$generation" ]
          fi
          rows=${legacyFrozenRows}
          published_plan=0
          if [ -n "$generation" ] && [ -f "$generation/plan.rows" ]; then
            rows="$generation/plan.rows"
            published_plan=1
            [ -f "$generation/persistent-plan.rows" ] || {
              echo "nixtache-overlay: selected persistent plan is missing" >&2
              exit 1
            }
          fi
          mountpoint -q ${physicalHostRoot}/nix/store
          frozen_parent() {
            local wanted=$1 row_id logical_id role row_parent rest
            while IFS='|' read -r row_id logical_id role row_parent rest; do
              if [ "$row_id" = "$wanted" ]; then
                printf '%s\n' "$row_parent"
                return 0
              fi
            done < "$rows"
            return 1
          }
          while IFS='|' read -r physical_id logical_id role parent rest; do
            [ -n "$physical_id" ] || continue
            [ "$role" = frozen-lower ] || continue
            frozen_root="${runtimeState}/frozen/$physical_id"
            upper_dir="$frozen_root/upper"
            private_upper="$frozen_root/private-upper"
            work_dir="$frozen_root/work"
            store_dir="$frozen_root/nix/store"
            mkdir -p "$store_dir"
            upper=""
            if [ -n "$generation" ]; then
              upper="$generation/nodes/$physical_id/upper"
              if [ "$published_plan" = 0 ] && [ ! -d "$upper" ]; then
                if [ "$logical_id" = host ]; then
                  upper="$generation/host/upper"
                else
                  upper="$generation/layers/$logical_id/upper"
                fi
              fi
              if [ "$published_plan" = 1 ] && ! grep -q "^$physical_id|" "$generation/persistent-plan.rows"; then
                upper=""
              elif [ "$published_plan" = 1 ] && [ ! -d "$upper" ]; then
                echo "nixtache-overlay: selected frozen upper is missing: $physical_id" >&2
                exit 1
              fi
              if [ ! -d "$upper" ]; then upper=""; fi
            fi
            if mountpoint -q "$store_dir"; then
              if [ -n "$upper" ] && [ "$(readlink -f "$upper_dir")" = "$upper" ]; then continue; fi
              if [ -z "$upper" ] && [ ! -L "$upper_dir" ]; then continue; fi
              echo "nixtache-overlay: cannot replace a mounted frozen lower from another generation" >&2
              exit 1
            fi
            rm -rf "$upper_dir" "$private_upper" "$work_dir"
            if [ -n "$upper" ]; then
              ln -s "$upper" "$upper_dir"
            else
              mkdir -p "$upper_dir"
            fi
            mkdir -p "$private_upper" "$work_dir"
            if [ "$parent" = - ]; then
              lower_root="${physicalHostRoot}/nix/store"
            else
              lower_root="${runtimeState}/frozen/$parent/nix/store"
            fi
            mountpoint -q "$lower_root"
            lower_layers="$upper_dir"
            ancestor="$parent"
            while [ "$ancestor" != - ]; do
              ancestor_upper="${runtimeState}/frozen/$ancestor/upper"
              lower_layers="$lower_layers:$ancestor_upper"
              ancestor=$(frozen_parent "$ancestor")
            done
            lower_layers="$lower_layers:${physicalHostRoot}/nix/store"
            # Independent lower layers avoid OverlayFS-over-OverlayFS stacking limits.
            mount -t overlay overlay -o lowerdir="$lower_layers",upperdir="$private_upper",workdir="$work_dir" "$store_dir"
            mount --bind "$store_dir" "$store_dir"
            mount -o remount,ro,bind "$store_dir"
          done < "$rows"
          ${parentRootActivationSnippet}
        '';
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

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
, ...
}:

with lib;

let
  topology = cfg._topology;
  runnerLayers = filter (node: node ? containerName) topology.nodes;
  frozenMounts = optionals abEnabled topology.frozenMounts;
  frozenMountByPhysical = topology.frozenMountByPhysical;
  frozenMountName = id: "nixtache-overlay-frozen-${id}";
  frozenMountUnit = id: "${frozenMountName id}.service";
  frozenMountUnits = map (mount: frozenMountUnit mount.id) frozenMounts;
  hostFrozenMount = if abEnabled && builtins.hasAttr "host" topology.frozenLowerByLogical
    then topology.frozenMountByPhysical.${topology.frozenLowerByLogical.host}
    else null;
  hostFrozenUnit = optional (hostFrozenMount != null) (frozenMountUnit hostFrozenMount.id);
  hostRuntimeLower = if hostFrozenMount == null then "/nix/store" else hostFrozenMount.storeDir;
  encodeStoreUri = value: replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ] value;
  hostLowerStore = if hostFrozenMount != null
    then "local?root=${hostFrozenMount.root}&state=${hostFrozenMount.stateDir}&read-only=true"
    else if abEnabled
    then "local?state=${lowerStateLink}&read-only=true"
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
          ++ frozenMountUnits;
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
          ++ optional abEnabled "nixtache-lower-store-db-load.service"
          ++ hostFrozenUnit;
        requires = [ "nixtache-overlay-select.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service"
          ++ hostFrozenUnit;
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
          ++ optional abEnabled "nixtache-lower-store-db-load.service"
          ++ frozenMountUnits;
        requires = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service"
          ++ frozenMountUnits;
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

    (mkIf (frozenMounts != [ ]) {
      systemd.services = listToAttrs (map (mount:
        let
          parentUnit = optional (mount.parent != null) (frozenMountUnit mount.parent);
          legacyUpper = if mount.logicalId == "host"
            then "$generation/host/upper"
            else "$generation/layers/${mount.logicalId}/upper";
        in
        nameValuePair (frozenMountName mount.id) {
          description = "Mount the selected frozen ${mount.id} Nix store read-only";
          wantedBy = [ "nixtache-overlay-ready.target" ];
          before = [ "nixtache-overlay-ready.target" ];
          after = [ "nixtache-overlay-select.service" ] ++ parentUnit;
          requires = [ "nixtache-overlay-select.service" ] ++ parentUnit;
          path = with pkgs; [ coreutils util-linux ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p ${mount.storeDir}
            slot=$(cat ${runtimeState}/selected-slot 2>/dev/null || true)
            generation=$(cat ${runtimeState}/selected-generation 2>/dev/null || true)
            if [ -n "$slot" ] || [ -n "$generation" ]; then
              [ -n "$slot" ] && [ -n "$generation" ]
              [ "$(readlink -f "${slotsDir}/$slot/current")" = "$generation" ]
            fi
            upper=""
            if [ -n "$generation" ]; then
              upper="$generation/nodes/${mount.id}/upper"
              if [ ! -d "$upper" ]; then upper=${legacyUpper}; fi
              if [ ! -d "$upper" ]; then upper=""; fi
            fi
            if mountpoint -q ${mount.storeDir}; then
              if [ -n "$upper" ] && [ "$(readlink -f ${mount.upperDir})" = "$upper" ]; then exit 0; fi
              if [ -z "$upper" ] && [ ! -L ${mount.upperDir} ]; then exit 0; fi
              echo "nixtache-overlay: cannot replace a mounted frozen lower from another generation" >&2
              exit 1
            fi
            rm -rf ${mount.upperDir} ${mount.privateUpperDir} ${mount.workDir}
            if [ -n "$upper" ]; then
              ln -s "$upper" ${mount.upperDir}
            else
              mkdir -p ${mount.upperDir}
            fi
            mkdir -p ${mount.privateUpperDir} ${mount.workDir}
            lower_root=${if mount.parent == null then "/nix/store" else frozenMountByPhysical.${mount.parent}.storeDir}
            mount -t overlay overlay -o lowerdir=${mount.upperDir}:"$lower_root",upperdir=${mount.privateUpperDir},workdir=${mount.workDir} ${mount.storeDir}
            mount --bind ${mount.storeDir} ${mount.storeDir}
            mount -o remount,ro,bind ${mount.storeDir}
          '';
        }
      ) frozenMounts);
    })

    (mkIf (runnerLayers != [ ]) {
      systemd.services = listToAttrs (map (node:
        let parentUnit = optional abEnabled
          (frozenMountUnit topology.frozenParentByLogical.${node.id}); in
        nameValuePair "container@${node.containerName}" {
          after = [ "nixtache-overlay-ready.target" ] ++ parentUnit;
          requires = [ "nixtache-overlay-ready.target" ] ++ parentUnit;
        }
      ) runnerLayers);
    })
  ]);
}

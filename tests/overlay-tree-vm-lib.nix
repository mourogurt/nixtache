{ nixpkgs
, self
, system ? "x86_64-linux"
, topology ? "sibling"
, upperOnUpdate ? "wipe"
, ephemeralNode ? null
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };

  treeBase = "/var/lib/nix-overlay/tree";
  layerIds = if topology == "nested" then [ "middle" "leaf" ]
    else if topology == "composed" then [ "a" "grand" "b" ]
    else [ "left" "right" ];
  nodeIds = [ "host" ] ++ layerIds;
  parentById = if topology == "nested" then {
    middle = null;
    leaf = "middle";
  } else if topology == "composed" then {
    a = null;
    grand = "a";
    b = null;
  } else {
    left = null;
    right = null;
  };

  ephemeralBase = if ephemeralNode == "host" then "/tmp/nix-overlay-host"
    else if ephemeralNode == "a" then "/tmp/nix-overlay-a"
    else null;
  roots = { host = "/"; } // lib.genAttrs layerIds (id: "${treeBase}/${id}/root");
  upperDirs = {
    host = if ephemeralNode == "host" then "${ephemeralBase}/upper" else "/var/lib/nix-overlay/upper";
  } // lib.genAttrs layerIds (id:
    if id == ephemeralNode then "${ephemeralBase}/upper" else "${treeBase}/${id}/upper"
  );
  workDirs = {
    host = if ephemeralNode == "host" then "${ephemeralBase}/work" else "/var/lib/nix-overlay/work";
  } // lib.genAttrs layerIds (id:
    if id == ephemeralNode then "${ephemeralBase}/work" else "${treeBase}/${id}/work"
  );
  stateDirs = { host = "/nix/var/nix"; }
    // lib.genAttrs layerIds (id: "${treeBase}/${id}/state");

  layers = map (id:
    let
      parent = parentById.${id};
      parentId = if parent == null then "host" else parent;
    in
    {
      inherit id parent;
      upperDir = upperDirs.${id};
      workDir = workDirs.${id};
      stateDir = stateDirs.${id};
      lowerRoot = roots.${parentId};
    }
  ) layerIds;

  physicalRoot = "/run/nixtache-overlay-tree/physical";
  lowerMountUnit = "nixtache-overlay-tree-lower-mount.service";
  mountUnitFor = id: "nixtache-overlay-tree-${id}-mount.service";
  mountUnitNames = [ lowerMountUnit ] ++ map mountUnitFor layerIds;
  parentUnitFor = id:
    let parent = parentById.${id}; in
    if parent == null then lowerMountUnit else mountUnitFor parent;
  lowerDirsFor = id:
    let parent = parentById.${id}; in
    if parent == null
    then "${upperDirs.host}:${physicalRoot}/nix/store"
    else "${roots.${parent}}/nix/store";

  runtimeModule = { pkgs, ... }: {
    fileSystems = lib.optionalAttrs (ephemeralNode != null) {
      ${ephemeralBase} = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=755" ];
      };
    };

    services.nixtache.overlay-nix = {
      enable = true;
      inherit upperOnUpdate layers;
      upperDir = upperDirs.host;
      workDir = workDirs.host;
    };

    systemd.services = {
      nixtache-overlay-tree-lower-mount = {
        description = "Mount the selected physical lower for flattened overlay-tree views";
        wantedBy = [ "nixtache-overlay-ready.target" ];
        before = [ "nixtache-overlay-ready.target" ];
        after = [ "nixtache-overlay-select.service" ];
        requires = [ "nixtache-overlay-select.service" ];
        path = with pkgs; [ coreutils util-linux gawk ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p ${physicalRoot}/nix/store
          if ! mountpoint -q ${physicalRoot}/nix/store; then
            slot=$(cat /run/nixtache-overlay/selected-slot 2>/dev/null || true)
            if [ -z "$slot" ]; then
              slot=$(lsblk -nrpo PARTUUID,PARTLABEL | awk -v label="nix-store_$(cat /etc/image-version)" 'BEGIN{IGNORECASE=1} $2 == label {print tolower($1); exit}')
            fi
            mount -o ro "/dev/disk/by-partuuid/$slot" ${physicalRoot}/nix/store
          fi
        '';
      };
    } // lib.listToAttrs (map (id: {
      name = "nixtache-overlay-tree-${id}-mount";
      value = {
        description = "Mount the ${id} local-overlay store over its prepared parent";
        wantedBy = [ "nixtache-overlay-ready.target" ];
        before = [ "nixtache-overlay-ready.target" ];
        after = [ "nixtache-overlay-select.service" (parentUnitFor id) ];
        requires = [ "nixtache-overlay-select.service" (parentUnitFor id) ];
        path = with pkgs; [ coreutils util-linux ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p ${roots.${id}}/nix/store ${upperDirs.${id}} ${workDirs.${id}} ${stateDirs.${id}}
          if ! mountpoint -q ${roots.${id}}/nix/store; then
            mount -t overlay overlay -o lowerdir=${lowerDirsFor id},upperdir=${upperDirs.${id}},workdir=${workDirs.${id}} ${roots.${id}}/nix/store
          fi
        '';
      };
    }) layerIds);

    systemd.targets.nixtache-overlay-ready = {
      after = mountUnitNames;
      requires = mountUnitNames;
    };
  };

  encodeStoreUri = value: lib.replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ] value;
  hostLower = "local?state=${dirOf upperDirs.host}/lower-state&read-only=true";
  hostStoreUrl = "local-overlay://?root=/&state=/nix/var/nix"
    + "&lower-store=${encodeStoreUri hostLower}"
    + "&upper-layer=${upperDirs.host}"
    + "&ignore-gc-delete-failure=true&check-mount=false";
  storeUrls = lib.foldl' (urls: id:
    let
      parent = parentById.${id};
      parentId = if parent == null then "host" else parent;
    in
    urls // {
      ${id} = "local-overlay://?root=${roots.${id}}&state=${stateDirs.${id}}"
        + "&lower-store=${encodeStoreUri urls.${parentId}}"
        + "&upper-layer=${upperDirs.${id}}"
        + "&ignore-gc-delete-failure=true&check-mount=false";
    }
  ) { host = hostStoreUrl; } layerIds;

  hostDependency = pkgs.runCommand "overlay-tree-host-dependency" { } ''
    printf 'host dependency\n' > $out
  '';
  sharedDependency = pkgs.runCommand "overlay-tree-shared-dependency" { } ''
    printf 'shared dependency\n' > $out
  '';
  leafDependency = pkgs.runCommand "overlay-tree-leaf-dependency" { } ''
    printf 'leaf dependency\n' > $out
  '';
  commonDependency = pkgs.runCommand "overlay-tree-common-dependency" { } ''
    printf 'common sibling dependency\n' > $out
  '';

  hostConsumer = pkgs.runCommand "overlay-tree-host-consumer" { } ''
    printf 'host consumer\n%s\n' "${hostDependency}" > $out
  '';
  sharedConsumer = pkgs.runCommand "overlay-tree-shared-consumer" { } ''
    printf 'shared consumer\n%s\n' "${sharedDependency}" > $out
  '';
  leafConsumer = pkgs.runCommand "overlay-tree-leaf-consumer" { } ''
    printf 'leaf consumer\n%s\n%s\n' "${leafDependency}" "${sharedConsumer}" > $out
  '';
  leftConsumer = pkgs.runCommand "overlay-tree-left-consumer" { } ''
    printf 'left consumer\n%s\n%s\n' "${commonDependency}" "${hostConsumer}" > $out
  '';
  rightConsumer = pkgs.runCommand "overlay-tree-right-consumer" { } ''
    printf 'right consumer\n%s\n%s\n' "${commonDependency}" "${hostConsumer}" > $out
  '';
  composedConsumer = pkgs.runCommand "overlay-tree-composed-consumer" { } ''
    printf 'composed consumer\n%s\n%s\n' "${sharedDependency}" "${commonDependency}" > $out
  '';

  topologyDependencies = [ hostDependency ]
    ++ (if topology == "nested" then [ sharedDependency leafDependency ]
      else if topology == "composed" then [ sharedDependency leafDependency commonDependency ]
      else [ commonDependency ]);
  topologyConsumers = if topology == "nested"
    then [ hostConsumer sharedConsumer leafConsumer ]
    else if topology == "composed"
    then [ hostConsumer composedConsumer leafConsumer rightConsumer sharedConsumer ]
    else [ hostConsumer leftConsumer rightConsumer ];
  consumersByNode = if topology == "nested" then {
    host = hostConsumer.outPath;
    middle = sharedConsumer.outPath;
    leaf = leafConsumer.outPath;
  } else if topology == "composed" then {
    host = hostConsumer.outPath;
    a = composedConsumer.outPath;
    grand = leafConsumer.outPath;
    b = rightConsumer.outPath;
  } else {
    host = hostConsumer.outPath;
    left = leftConsumer.outPath;
    right = rightConsumer.outPath;
  };
  repairCases = if topology == "nested" then [
    { path = hostDependency.outPath; nodes = [ "host" ]; }
    { path = sharedDependency.outPath; nodes = [ "middle" ]; }
    { path = leafDependency.outPath; nodes = [ "leaf" ]; }
  ] else if topology == "composed" then [
    { path = hostDependency.outPath; nodes = [ "host" ]; }
    { path = sharedDependency.outPath; nodes = [ "a" ]; }
    { path = leafDependency.outPath; nodes = [ "grand" ]; }
    { path = commonDependency.outPath; nodes = [ "a" "b" ]; }
  ] else [
    { path = hostDependency.outPath; nodes = [ "host" ]; }
    { path = commonDependency.outPath; nodes = [ "left" "right" ]; }
  ];
  extraRoots = lib.optional (topology == "nested" || topology == "composed") {
    node = if topology == "nested" then "leaf" else "grand";
    path = sharedConsumer.outPath;
    name = "shared-from-middle";
  };

  mkAppliance = { version, withDependencies ? false, extraModules ? [ ] }: otaLib.mkAppliance {
    inherit version;
    storeSize = "1G";
    extraPackages = [ pkgs.sqlite ];
    extraModules = [
      self.nixosModules.overlay-nix
      runtimeModule
      { system.extraDependencies = lib.optionals withDependencies topologyDependencies; }
    ] ++ extraModules;
  };
  v1 = mkAppliance { version = "1"; withDependencies = true; };
  v2 = mkAppliance { version = "2"; };
  v2SysupdatePkg = v2.config.system.build.sysupdate-package;
in
assert lib.assertMsg (builtins.elem topology [ "sibling" "nested" "composed" ]) "overlay-tree topology must be sibling, nested or composed";
assert lib.assertMsg (builtins.elem upperOnUpdate [ "wipe" "reconcile" ]) "overlay-tree upperOnUpdate must be wipe or reconcile";
assert lib.assertMsg (ephemeralNode == null || builtins.elem ephemeralNode [ "host" "a" ]) "overlay-tree ephemeralNode must be null, host or a";
{
  inherit lib pkgs otaLib nodeIds layerIds roots upperDirs workDirs stateDirs storeUrls mountUnitNames;
  inherit consumersByNode repairCases extraRoots v2SysupdatePkg runtimeModule mkAppliance;
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  deployerDependencies = [ v2SysupdatePkg ] ++ topologyDependencies ++ topologyConsumers;
  fixturePaths = {
    hostDependency = hostDependency.outPath;
    sharedDependency = sharedDependency.outPath;
    leafDependency = leafDependency.outPath;
    commonDependency = commonDependency.outPath;
    hostConsumer = hostConsumer.outPath;
    sharedConsumer = sharedConsumer.outPath;
  };
}

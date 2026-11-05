{ config, lib, cfg, runtimeState, ... }:

with lib;

let
  runnerCfg = config.services.nixtache.runner or { };
  runnerDeclarations = runnerCfg._declarations or { };
  runnerLayers = mapAttrsToList (id: declaration:
    let store = declaration.store; in {
      inherit id;
      parent = store.parent;
      upperDir = "${store.hostBackup}/overlay/upper";
      workDir = "${store.hostBackup}/overlay/work";
      stateDir = "${store.hostBackup}/nix/var/nix";
      lowerRoot = if declaration.isSingleton
        then "/run/nixtache-runner-lower"
        else "/run/nixtache-runner-lower/${id}";
      containerName = declaration.containerName;
      isSingleton = declaration.isSingleton;
    }
  ) (filterAttrs (_: declaration:
    declaration.enable
    && declaration.store.path != "/"
    && declaration.store.mode == "overlay"
  ) runnerDeclarations);

  configuredLayers = cfg._layers;
  topologyNodes = [
    {
      id = "host";
      parent = null;
      inherit (cfg) upperDir workDir;
      stateDir = "/nix/var/nix";
      lowerRoot = "";
    }
  ] ++ configuredLayers ++ runnerLayers;
  topologyIds = map (node: node.id) topologyNodes;
  childrenOf = parent: builtins.filter (node: node.id != "host" && (if node.parent == null then "host" else node.parent) == parent) topologyNodes;
  visitTopology = parent: path:
    if builtins.elem parent path then
      throw "services.nixtache.overlay-nix: topology cycle detected: ${concatStringsSep " -> " (path ++ [ parent ])}"
    else
      [ parent ] ++ builtins.concatLists (map
        (node: visitTopology node.id (path ++ [ parent ]))
        (childrenOf parent));
  sortedNodeIds = visitTopology "host" [ ];
  sortedTopology = map (id: builtins.head (builtins.filter (node: node.id == id) topologyNodes)) sortedNodeIds;
  nodesById = listToAttrs (map (node: nameValuePair node.id node) topologyNodes);
  pathComponents = path: filter (component: component != "" && component != ".") (splitString "/" path);
  pathIsPrefix = parent: child:
    let
      parentComponents = pathComponents parent;
      childComponents = pathComponents child;
    in
    builtins.length parentComponents <= builtins.length childComponents
    && take (builtins.length parentComponents) childComponents == parentComponents;
  pathsOverlap = a: b: pathIsPrefix a b || pathIsPrefix b a;
  pathEntries = concatMap (node: map (kind: {
    owner = "${node.id}.${kind}";
    path = node.${kind};
  }) [ "upperDir" "workDir" "stateDir" ]) topologyNodes;
  pathPairs = concatMap (a: map (b: { inherit a b; }) pathEntries) pathEntries;
  pathCollisions = filter (pair:
    pair.a.owner != pair.b.owner && pathsOverlap pair.a.path pair.b.path
  ) pathPairs;
  unsafeManagedPaths = filter (entry:
    !hasPrefix "/" entry.path || builtins.elem ".." (splitString "/" entry.path)
  ) pathEntries;
  fileSystemForPath = path:
    builtins.foldl' (best: fileSystem:
      if pathIsPrefix fileSystem.mountPoint path
        && (best == null || builtins.length (pathComponents fileSystem.mountPoint)
          > builtins.length (pathComponents best.mountPoint))
      then fileSystem
      else best
    ) null (builtins.attrValues config.fileSystems);
  pathIsEphemeral = path:
    let fileSystem = fileSystemForPath path; in
    fileSystem != null && (fileSystem.fsType or "") == "tmpfs";
  ephemeralById = builtins.foldl' (result: node:
    let
      parent = if node.id == "host" then null else if node.parent == null then "host" else node.parent;
      inherited = parent != null && (result.${parent} or false);
    in
    result // {
      ${node.id} = inherited || pathIsEphemeral node.upperDir;
    }
  ) { } sortedTopology;
  declaredTopology = map (node: node // {
    ephemeral = ephemeralById.${node.id};
  }) sortedTopology;
  topologyFingerprint = builtins.hashString "sha256" (builtins.toJSON
    (map (node: { inherit (node) id parent; }) sortedTopology));
  physicalLib = import ./physical.nix { inherit lib; };
  physicalTopology = physicalLib.derive { logicalNodes = declaredTopology; };
  duplicatePhysicalIds = physicalLib.duplicatePhysicalIds physicalTopology.physical.nodes;
  parentRoot = logicalId: "${runtimeState}/parents/${logicalId}";
  physicalHostRoot = "${runtimeState}/physical-host";
  frozenRoot = physicalId: "${runtimeState}/frozen/${physicalId}";
  frozenParentByLogical = mapAttrs
    (_: consumerId: physicalTopology.physical.byId.${consumerId}.parent)
    physicalTopology.consumerNodeByLogical;
  frozenMounts = map (node:
    let root = frozenRoot node.id; in {
      inherit (node) id logicalId parent;
      inherit root;
      upperDir = "${root}/upper";
      privateUpperDir = "${root}/private-upper";
      workDir = "${root}/work";
      storeDir = "${root}/nix/store";
      stateDir = "${root}/nix/var/nix";
    }
  ) (builtins.filter (node: node.role == "frozen-lower") physicalTopology.physical.nodes);
  frozenMountByPhysical = listToAttrs (map (mount:
    nameValuePair mount.id mount
  ) frozenMounts);
  logicalDescriptor = {
    fingerprint = topologyFingerprint;
    order = sortedNodeIds;
    nodes = map (node: {
      inherit (node) id parent upperDir workDir stateDir lowerRoot;
    } // optionalAttrs node.ephemeral {
      inherit (node) ephemeral;
    } // optionalAttrs (node ? containerName) {
      inherit (node) containerName;
    } // optionalAttrs (node ? isSingleton) {
      inherit (node) isSingleton;
    }) declaredTopology;
  };
in
{
  config = mkIf cfg.enable {
    services.nixtache.overlay-nix._topology = physicalTopology // {
      nodes = topologyNodes;
      byId = nodesById;
      order = sortedNodeIds;
      fingerprint = topologyFingerprint;
      descriptor = logicalDescriptor;
      inherit frozenParentByLogical frozenMounts frozenMountByPhysical parentRoot physicalHostRoot frozenRoot;
      rebase = args: physicalLib.derive ({
        logicalNodes = declaredTopology;
        previousPhysical = physicalTopology.physical.nodes;
      } // args);
      transition = args: physicalLib.transition ({
        sourceLogical = declaredTopology;
        previousPhysical = physicalTopology.physical.nodes;
      } // args);
    };
    assertions = [
      {
        assertion = (builtins.compareVersions config.nix.package.version "2.19") >= 0;
        message = "services.nixtache.overlay-nix requires Nix >= 2.19 for local-overlay-store";
      }
      {
        assertion = builtins.all (id:
          builtins.match "[A-Za-z0-9._-]+" id != null && !builtins.elem id [ "." ".." ]
        ) topologyIds;
        message = "services.nixtache.overlay-nix: node identities must be safe, unique path components.";
      }
      {
        assertion = builtins.length topologyIds == builtins.length (lists.unique topologyIds);
        message = "services.nixtache.overlay-nix: duplicate node identity in the upper topology.";
      }
      {
        assertion = duplicatePhysicalIds == [ ];
        message = "services.nixtache.overlay-nix: derived physical node identities must be unique; collisions: ${concatStringsSep ", " duplicatePhysicalIds}. Logical IDs must not reuse generated '-lower' or '-runtime' identities.";
      }
      {
        assertion = builtins.all (node:
          node.id == "host" || node.parent == null || builtins.elem node.parent topologyIds
        ) topologyNodes;
        message = "services.nixtache.overlay-nix: every parent must name an eligible existing overlay node.";
      }
      {
        assertion = builtins.length sortedNodeIds == builtins.length topologyIds;
        message = "services.nixtache.overlay-nix: every node must be reachable from the host root without cycles.";
      }
      {
        assertion = unsafeManagedPaths == [ ];
        message = "services.nixtache.overlay-nix: managed paths must be absolute and cannot contain '..' components.";
      }
      {
        assertion = pathCollisions == [ ];
        message = "services.nixtache.overlay-nix: upper, work and state paths must be component-wise disjoint within and across nodes.";
      }
    ];
  };
}

{ lib }:

rec {
  duplicatePhysicalIds = physicalNodes:
    let
      counts = lib.foldl' (result: node: result // {
        ${node.id} = (result.${node.id} or 0) + 1;
      }) { } physicalNodes;
    in
    lib.attrNames (lib.filterAttrs (_: count: count > 1) counts);

  derive =
    { logicalNodes
    , previousPhysical ? [ ]
    , viewFingerprints ? { }
    }:
    let
      logicalById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) logicalNodes);
      logicalIds = map (node: node.id) logicalNodes;
      childrenOf = parent: builtins.filter (node:
        node.id != "host" && (if node.parent == null then "host" else node.parent) == parent
      ) logicalNodes;
      visit = parent: path:
        if builtins.elem parent path then
          throw "overlay topology cycle: ${lib.concatStringsSep " -> " (path ++ [ parent ])}"
        else
          [ parent ] ++ builtins.concatLists (map
            (node: visit node.id (path ++ [ parent ]))
            (childrenOf parent));
      sortedLogical = map (id: logicalById.${id}) (visit "host" [ ]);
      previousSplitIds = map (node: node.logicalId) (builtins.filter
        (node: node.role == "frozen-lower") previousPhysical);
      parentIds = map (node: node.id) (builtins.filter
        (node: childrenOf node.id != [ ]) logicalNodes);
      splitIds = builtins.filter (id: builtins.elem id logicalIds)
        (lib.lists.unique (parentIds ++ previousSplitIds));
      isSplit = id: builtins.elem id splitIds;
      physicalParent = node:
        if node.id == "host" then
          null
        else
          let parent = if node.parent == null then "host" else node.parent; in
          if isSplit parent then "${parent}-lower" else parent;
      runtimeNode = node: id: parent: {
        inherit id parent;
        logicalId = node.id;
        role = "runtime";
        inherit (node) upperDir workDir stateDir lowerRoot;
      } // lib.optionalAttrs (isSplit node.id && id == "${node.id}-runtime") {
        rebasedFrom = viewFingerprints.${node.id} or null;
      };
      nodesFor = node:
        if isSplit node.id then [
          {
            id = "${node.id}-lower";
            logicalId = node.id;
            role = "frozen-lower";
            parent = physicalParent node;
            upperDir = null;
            workDir = null;
            stateDir = null;
            lowerRoot = null;
            viewFingerprint = viewFingerprints.${node.id} or null;
          }
          (runtimeNode node "${node.id}-runtime" "${node.id}-lower")
        ] else [
          (runtimeNode node node.id (physicalParent node))
        ];
      basePhysicalNodes = builtins.concatLists (map nodesFor sortedLogical);
      ephemeralByPhysical = builtins.foldl' (result: node:
        result // {
          ${node.id} = (logicalById.${node.logicalId}.ephemeral or false)
            || (node.parent != null && (result.${node.parent} or false));
        }
      ) { } basePhysicalNodes;
      physicalNodes = map (node:
        node // lib.optionalAttrs ephemeralByPhysical.${node.id} {
          ephemeral = true;
        }
      ) basePhysicalNodes;
      duplicateIds = duplicatePhysicalIds physicalNodes;
      physicalById =
        if duplicateIds != [ ] then
          throw "derived physical node identities must be unique; collisions: ${lib.concatStringsSep ", " duplicateIds}"
        else
          lib.listToAttrs (map (node: lib.nameValuePair node.id node) physicalNodes);
      consumerNodeByLogical = lib.listToAttrs (map (node:
        lib.nameValuePair node.id (if isSplit node.id then "${node.id}-runtime" else node.id)
      ) sortedLogical);
      frozenLowerByLogical = lib.listToAttrs (map (id:
        lib.nameValuePair id "${id}-lower"
      ) splitIds);
      lineageFor = id:
        let node = physicalById.${id}; in
        {
          inherit (node) logicalId role;
          parent = if node.parent == null then null else lineageFor node.parent;
          storage = if node.role == "runtime" then {
            inherit (node) upperDir workDir stateDir;
          } else null;
          viewFingerprint = node.viewFingerprint or null;
          rebasedFrom = node.rebasedFrom or null;
        } // lib.optionalAttrs (node.ephemeral or false) {
          ephemeral = true;
        };
      lineageByPhysical = lib.mapAttrs (id: _: lineageFor id) physicalById;
      generationFingerprint = builtins.hashString "sha256" (builtins.toJSON {
        logical = map (node: {
          inherit (node) id parent upperDir workDir stateDir;
        } // lib.optionalAttrs (node.ephemeral or false) {
          ephemeral = true;
        }) sortedLogical;
        physical = lineageByPhysical;
      });
    in
    {
      nodes = sortedLogical;
      byId = logicalById;
      order = map (node: node.id) sortedLogical;
      physical = {
        nodes = physicalNodes;
        byId = physicalById;
        order = map (node: node.id) physicalNodes;
      };
      inherit consumerNodeByLogical frozenLowerByLogical lineageByPhysical generationFingerprint;
    };

  transition =
    { sourceLogical
    , previousPhysical
    , targetLogical
    , policy ? "reconcile"
    , viewFingerprints ? { }
    }:
    let
      derived = derive {
        logicalNodes = targetLogical;
        inherit previousPhysical viewFingerprints;
      };
      sourceById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) sourceLogical);
      targetById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) targetLogical);
      allIds = lib.lists.unique ((map (node: node.id) sourceLogical) ++ (map (node: node.id) targetLogical));
      operationFor = id:
        if !(targetById ? ${id}) then
          "remove"
        else if !(sourceById ? ${id}) then
          "add"
        else if sourceById.${id}.upperDir != targetById.${id}.upperDir
          || sourceById.${id}.stateDir != targetById.${id}.stateDir
          || (sourceById.${id}.ephemeral or false) != (targetById.${id}.ephemeral or false) then
          "storage-reset"
        else if sourceById.${id}.parent != targetById.${id}.parent then
          "reparent"
        else if !(builtins.elem "${id}-lower" (map (node: node.id) previousPhysical))
          && derived.physical.byId ? "${id}-lower" then
          "promote"
        else if sourceById.${id}.workDir != targetById.${id}.workDir
          || (sourceById.${id}.lowerRoot or null) != (targetById.${id}.lowerRoot or null)
          || (sourceById.${id}.containerName or null) != (targetById.${id}.containerName or null) then
          "rewire"
        else
          "unchanged";
      operations = lib.listToAttrs (map (id: lib.nameValuePair id (operationFor id)) allIds);
      dispositionFor = node:
        if node.role == "frozen-lower" then
          "freeze"
        else if policy == "wipe" then
          "empty"
        else if operations.${node.logicalId} == "add"
          || operations.${node.logicalId} == "storage-reset" then
          "empty"
        else if node.id == "${node.logicalId}-runtime" then
          "empty-continuation"
        else
          "clone-and-repair";
      dispositions = lib.listToAttrs (map (node:
        lib.nameValuePair node.id (dispositionFor node)
      ) derived.physical.nodes);
    in
    derived // {
      inherit operations dispositions;
      transition = nextArgs: transition ({
        sourceLogical = targetLogical;
        previousPhysical = derived.physical.nodes;
      } // nextArgs);
    };
}

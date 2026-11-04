{ lib }:

rec {
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
      physicalNodes = builtins.concatLists (map nodesFor sortedLogical);
      physicalById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) physicalNodes);
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
        };
      lineageByPhysical = lib.mapAttrs (id: _: lineageFor id) physicalById;
      generationFingerprint = builtins.hashString "sha256" (builtins.toJSON {
        logical = map (node: {
          inherit (node) id parent upperDir workDir stateDir;
        }) sortedLogical;
        physical = lineageByPhysical;
      });
    in
    {
      physical = {
        nodes = physicalNodes;
        byId = physicalById;
        order = map (node: node.id) physicalNodes;
      };
      inherit consumerNodeByLogical frozenLowerByLogical lineageByPhysical generationFingerprint;
    };
}

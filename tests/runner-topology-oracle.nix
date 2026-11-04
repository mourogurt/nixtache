{ lib }:

rec {
  node = id: overrides: {
    parent = null;
    mode = "overlay";
    path = "/srv/${id}";
    hostBackup = "/var/lib/runners/${id}";
    containerName = id;
    enable = true;
  } // overrides;

  childrenOf = state: id: builtins.filter
    (name: (state.${name}.parent or null) == id)
    (builtins.attrNames state);

  subtreeIds = state: id: [ id ] ++ lib.concatMap
    (child: subtreeIds state child)
    (childrenOf state id);

  applyOperation = state: operation:
    if operation.type == "add" then
      state // {
        ${operation.id} = node operation.id operation.settings;
      }
    else if operation.type == "reparent" then
      state // {
        ${operation.id} = state.${operation.id} // { parent = operation.parent; };
      }
    else if operation.type == "remove-leaf" then
      if childrenOf state operation.id != [ ] then
        throw "operation oracle refuses to orphan children of ${operation.id}"
      else
        removeAttrs state [ operation.id ]
    else if operation.type == "remove-subtree" then
      removeAttrs state (subtreeIds state operation.id)
    else if operation.type == "storage" then
      state // {
        ${operation.id} = state.${operation.id} // operation.changes;
      }
    else if operation.type == "mode" then
      state // {
        ${operation.id} = state.${operation.id} // {
          inherit (operation) mode;
        } // lib.optionalAttrs (operation ? path) { inherit (operation) path; };
      }
    else
      throw "unknown runner topology operation: ${operation.type}";

  modelsFor = initial: operations:
    (lib.foldl'
      (accumulator: operation:
        let next = applyOperation accumulator.state operation; in
        {
          state = next;
          models = accumulator.models ++ [ next ];
        })
      { state = initial; models = [ initial ]; }
      operations).models;

  logicalNodes = state:
    let
      host = {
        id = "host";
        parent = null;
        upperDir = "/var/lib/nix-overlay/upper";
        workDir = "/var/lib/nix-overlay/work";
        stateDir = "/nix/var/nix";
        lowerRoot = "";
      };
      runnerNode = id:
        let declaration = state.${id}; in
        {
          inherit id;
          inherit (declaration) parent containerName;
          isSingleton = false;
          upperDir = "${declaration.hostBackup}/overlay/upper";
          workDir = "${declaration.hostBackup}/overlay/work";
          stateDir = "${declaration.hostBackup}/nix/var/nix";
          lowerRoot = "/run/nixtache-runner-lower/${id}";
        };
      eligible = builtins.filter
        (id: state.${id}.enable
          && state.${id}.path != "/"
          && state.${id}.mode == "overlay")
        (builtins.attrNames state);
    in
    [ host ] ++ map runnerNode eligible;

  derive =
    { state
    , previousPhysical ? [ ]
    , logical ? logicalNodes state
    }:
    let
      logicalById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) logical);
      logicalIds = map (node: node.id) logical;
      logicalChildrenOf = parent: builtins.filter
        (node: node.id != "host" && (if node.parent == null then "host" else node.parent) == parent)
        logical;
      visit = parent: path:
        if builtins.elem parent path then
          throw "operation oracle cycle: ${lib.concatStringsSep " -> " (path ++ [ parent ])}"
        else
          [ parent ] ++ lib.concatLists (map
            (node: visit node.id (path ++ [ parent ]))
            (logicalChildrenOf parent));
      orderedIds = visit "host" [ ];
      sortedLogical = map (id: logicalById.${id}) orderedIds;
      previousSplitIds = map (node: node.logicalId) (builtins.filter
        (node: node.role == "frozen-lower") previousPhysical);
      parentIds = map (node: node.id) (builtins.filter
        (node: logicalChildrenOf node.id != [ ]) logical);
      splitIds = builtins.filter
        (id: builtins.elem id logicalIds)
        (lib.unique (parentIds ++ previousSplitIds));
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
        rebasedFrom = null;
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
            viewFingerprint = null;
          }
          (runtimeNode node "${node.id}-runtime" "${node.id}-lower")
        ] else [
          (runtimeNode node node.id (physicalParent node))
        ];
      physicalNodes = lib.concatLists (map nodesFor sortedLogical);
      physicalById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) physicalNodes);
      consumerNodeByLogical = lib.listToAttrs (map (node:
        lib.nameValuePair node.id (if isSplit node.id then "${node.id}-runtime" else node.id)
      ) sortedLogical);
      frozenLowerByLogical = lib.listToAttrs (map
        (id: lib.nameValuePair id "${id}-lower")
        splitIds);
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
      nodes = sortedLogical;
      order = orderedIds;
      physical = {
        nodes = physicalNodes;
        order = map (node: node.id) physicalNodes;
      };
      inherit consumerNodeByLogical frozenLowerByLogical lineageByPhysical generationFingerprint;
    };

  transition =
    { sourceState
    , targetState
    , previousPhysical
    , policy ? "reconcile"
    }:
    let
      sourceLogical = logicalNodes sourceState;
      targetLogical = logicalNodes targetState;
      derived = derive {
        state = targetState;
        logical = targetLogical;
        inherit previousPhysical;
      };
      sourceById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) sourceLogical);
      targetById = lib.listToAttrs (map (node: lib.nameValuePair node.id node) targetLogical);
      allIds = lib.unique ((map (node: node.id) sourceLogical) ++ (map (node: node.id) targetLogical));
      operationFor = id:
        if !(targetById ? ${id}) then
          "remove"
        else if !(sourceById ? ${id}) then
          "add"
        else if sourceById.${id}.upperDir != targetById.${id}.upperDir
          || sourceById.${id}.stateDir != targetById.${id}.stateDir then
          "storage-reset"
        else if sourceById.${id}.parent != targetById.${id}.parent then
          "reparent"
        else if !(builtins.elem "${id}-lower" (map (node: node.id) previousPhysical))
          && builtins.elem "${id}-lower" (map (node: node.id) derived.physical.nodes) then
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
      dispositions = lib.listToAttrs (map
        (node: lib.nameValuePair node.id (dispositionFor node))
        derived.physical.nodes);
    in
    derived // {
      inherit operations dispositions;
    };

  physicalProjection = node: {
    inherit (node) id logicalId role parent;
  };

  graphProjection = graph: {
    inherit (graph) nodes order consumerNodeByLogical frozenLowerByLogical;
    inherit (graph) lineageByPhysical generationFingerprint;
    physical = {
      nodes = map physicalProjection graph.physical.nodes;
      inherit (graph.physical) order;
    };
  };

  projection = graph: graphProjection graph
    // lib.optionalAttrs (graph ? operations) { inherit (graph) operations; }
    // lib.optionalAttrs (graph ? dispositions) { inherit (graph) dispositions; };
}

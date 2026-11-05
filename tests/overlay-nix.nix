{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
    services.nixtache.overlay-nix.enable = true;
  };

  mkHost = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.overlay-nix
        baseModule
        extra
      ];
    };

  mkRunnerAppliance = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.runner
        self.nixosModules.overlay-nix
        self.nixosModules.ab-image
        baseModule
        {
          services.nixtache.runner = {
            enable = true;
            forgejoUrl = "http://localhost:3000";
            cache.enable = false;
          };
          services.nixtache.ab-image = {
            enable = true;
            imageId = "nixtache";
          };
          nix.enable = false;
        }
        extra
      ];
    };

  cfgOf = host: host.config.services.nixtache.overlay-nix;
  servicesOf = host: host.config.systemd.services;

  hostDefault = mkHost { };
  svcDefault = servicesOf hostDefault;
  selectScript = svcDefault.nixtache-overlay-select.script;
  prepareCommand = svcDefault.nixtache-overlay-prepare.script;
  prepareScript = builtins.readFile (builtins.head (lib.splitString " " prepareCommand));

  scenarioDefault = {
    name = "persistent uppers use physical-slot metaslots and stable selection paths";
    checks = {
      defaultIsWipe = (cfgOf hostDefault).upperOnUpdate == "wipe";
      selectionExists = svcDefault ? nixtache-overlay-select;
      preparationExists = svcDefault ? nixtache-overlay-prepare;
      selectionBeforeMount = builtins.elem "nix-daemon-overlay-mount.service" svcDefault.nixtache-overlay-select.before;
      mountRequiresSelection = builtins.elem "nixtache-overlay-select.service" svcDefault.nix-daemon-overlay-mount.requires;
      daemonRequiresReadiness = builtins.elem "nixtache-overlay-ready.target" svcDefault.nix-daemon.requires;
      slotLayout = lib.hasInfix "upper-slots" selectScript
        && lib.hasInfix "/host/upper" selectScript
        && lib.hasInfix "/host/lower-state" selectScript;
      identityFailsClosed = lib.hasInfix "has no GPT PARTUUID" prepareScript
        && lib.hasInfix "ambiguous PARTUUID" prepareScript;
      noLegacyLifecycle = !(svcDefault ? nixtache-overlay-lifecycle);
      noPreupdateUnit = !(svcDefault ? nixtache-overlay-preupdate);
    };
  };

  hostReconcile = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "reconcile"; };
  reconcileCommand = hostReconcile.config.systemd.services.nixtache-overlay-prepare.script;
  reconcileScript = builtins.readFile (builtins.head (lib.splitString " " reconcileCommand));
  scenarioReconcile = {
    name = "reconcile clones a ready active generation and resumes writers before target repair";
    checks = {
      valueIsReconcile = (cfgOf hostReconcile).upperOnUpdate == "reconcile";
      clonesActiveGeneration = lib.hasInfix ''"$materializer" "$stage/plan.rows" "$source_dir" "$stage"'' reconcileScript;
      quiescesWriters = lib.hasInfix "nix-daemon.socket" reconcileScript;
      verifiesPrivateTarget = lib.hasInfix "unshare -m --propagation private" reconcileScript;
      readinessIsExplicit = lib.hasInfix "state=unready" reconcileScript
        && lib.hasInfix "state=ready" reconcileScript;
      activeIsNeverRepairTarget = !(lib.hasInfix "repair_store \"$host_url\" \"/nix/var/nix\"" reconcileScript);
    };
  };

  hostWipe = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "wipe"; };
  scenarioWipe = {
    name = "wipe retains the two-value policy and prepares only a target generation";
    checks = {
      valueIsWipe = (cfgOf hostWipe).upperOnUpdate == "wipe";
      noLegacyLifecycle = !((servicesOf hostWipe) ? nixtache-overlay-lifecycle);
      preparationUsesStaging = lib.hasInfix ".staging-" prepareScript;
      readinessIsAtomic = lib.hasInfix "mv \"$stage\" \"$slot_dir/generations/$generation\"" prepareScript;
    };
  };

  layer = id: parent: {
    inherit id parent;
    upperDir = "/var/lib/layers/${id}/upper";
    workDir = "/var/lib/layers/${id}/work";
    stateDir = "/var/lib/layers/${id}/state";
  };
  hostWithLayers = layers: mkHost {
    services.nixtache.overlay-nix = {
      _layers = layers;
      upperOnUpdate = "reconcile";
    };
  };
  scriptWithLayers = layers: let
    host = hostWithLayers layers;
  in builtins.readFile (builtins.head (lib.splitString " "
    host.config.systemd.services.nixtache-overlay-prepare.script));
  namespaceWithLayers = layers: let
    script = scriptWithLayers layers;
  in builtins.readFile (builtins.head (lib.splitString "\n"
    (builtins.elemAt (lib.splitString "unshare -m --propagation private " script) 1)));
  selectWithLayers = layers: (hostWithLayers layers).config.systemd.services.nixtache-overlay-select.script;
  tryHost = extra: builtins.tryEval (mkHost {
    imports = [ extra ];
    fileSystems."/" = {
      device = "/dev/sda";
      fsType = "ext4";
    };
    boot.loader.grub.devices = [ "/dev/sda" ];
  }).config.system.build.toplevel.outPath;
  tryLayers = layers: tryHost {
    services.nixtache.overlay-nix = {
      _layers = layers;
      upperOnUpdate = "reconcile";
    };
  };
  topologyWithLayers = layers: (cfgOf (hostWithLayers layers))._topology;
  posOf = pat: s: lib.stringLength (builtins.head (lib.splitString pat s));
  indexOf = id: values: let
    go = index: remaining:
      if remaining == [ ] then -1
      else if builtins.head remaining == id then index
      else go (index + 1) (builtins.tail remaining);
  in go 0 values;

  descriptorValidator = builtins.head (lib.splitString "\n"
    (builtins.elemAt (lib.splitString "descriptor_validator=" prepareScript) 1));
  descriptorLowerSha = builtins.concatStringsSep "" (lib.genList (_: "a") 64);
  otherLowerSha = builtins.concatStringsSep "" (lib.genList (_: "b") 64);
  validDescriptor = pkgs.writeText "valid-overlay-topology.json" (builtins.toJSON {
    schema = "nixtache.overlay-topology/v1";
    imageId = "nixtache";
    imageVersion = "1";
    lowerDbSha256 = descriptorLowerSha;
    logicalTopology = (cfgOf hostDefault)._topology.descriptor;
  });
  malformedDescriptor = pkgs.writeText "malformed-overlay-topology.json" "{";
  wrongSchemaDescriptor = pkgs.writeText "wrong-schema-overlay-topology.json" (builtins.toJSON ({
    schema = "nixtache.overlay-topology/v1";
    imageId = "nixtache";
    imageVersion = "1";
    lowerDbSha256 = descriptorLowerSha;
    logicalTopology = (cfgOf hostDefault)._topology.descriptor;
  } // { schema = "other/v1"; }));
  wrongGraphDescriptor = pkgs.writeText "wrong-graph-overlay-topology.json" (builtins.toJSON {
    schema = "nixtache.overlay-topology/v1";
    imageId = "nixtache";
    imageVersion = "1";
    lowerDbSha256 = descriptorLowerSha;
    logicalTopology = (cfgOf hostDefault)._topology.descriptor // {
      fingerprint = otherLowerSha;
    };
  });
  descriptorValidationCheck = pkgs.runCommand "overlay-descriptor-validation-test" {
    inherit descriptorValidator validDescriptor malformedDescriptor wrongSchemaDescriptor wrongGraphDescriptor;
    inherit descriptorLowerSha otherLowerSha;
  } ''
    set -euo pipefail
    "$descriptorValidator" "$validDescriptor" 1 "$descriptorLowerSha"
    expect_failure() {
      local name=$1
      shift
      if "$@" >"/tmp/$name.log" 2>&1; then
        echo "descriptor case unexpectedly passed: $name" >&2
        exit 1
      fi
    }
    expect_failure missing "$descriptorValidator" /does-not-exist.overlay-topology.json 1 "$descriptorLowerSha"
    expect_failure malformed "$descriptorValidator" "$malformedDescriptor" 1 "$descriptorLowerSha"
    expect_failure schema "$descriptorValidator" "$wrongSchemaDescriptor" 1 "$descriptorLowerSha"
    expect_failure image "$descriptorValidator" "$validDescriptor" 2 "$descriptorLowerSha"
    expect_failure lower "$descriptorValidator" "$validDescriptor" 1 "$otherLowerSha"
    expect_failure graph "$descriptorValidator" "$wrongGraphDescriptor" 1 "$descriptorLowerSha"
    touch "$out"
  '';
  scenarioDescriptorValidation = {
    name = "target descriptors are validated before staging and bound into readiness metadata";
    checks = {
      missingAndMalformedRejected = lib.isDerivation descriptorValidationCheck;
      descriptorHashRecorded = lib.hasInfix "descriptor_sha256" prepareScript;
      logicalFingerprintValidated = lib.isDerivation plannerTransitionCheck;
      imageAndLowerValidated = lib.isDerivation descriptorValidationCheck;
      validationBeforeStaging = (posOf ''"$descriptor_validator" "$target_descriptor"'' prepareScript)
        < (posOf ''mkdir -p "$slot_dir/generations"'' prepareScript);
    };
  };

  scenarioPublicLayersRejected = {
    name = "low-level overlay layers are not a consumer-facing option";
    checks.rejected = !(tryHost {
      services.nixtache.overlay-nix.layers = [ ];
    }).success;
  };

  siblingScript = scriptWithLayers [ (layer "a" null) (layer "b" null) ];
  siblingSelection = selectWithLayers [ (layer "a" null) (layer "b" null) ];
  siblingTopology = topologyWithLayers [ (layer "a" null) (layer "b" null) ];
  scenarioSiblings = {
    name = "sibling overlays share the host parent and one atomic readiness result";
    checks = {
      stagesBoth = lib.isDerivation plannerTransitionCheck;
      hostFirst = indexOf "host-lower" siblingTopology.physical.order
        < indexOf "a" siblingTopology.physical.order
        && indexOf "host-runtime" siblingTopology.physical.order
          < indexOf "b" siblingTopology.physical.order;
      activatesBoth = lib.hasInfix "$generation/nodes/a" siblingSelection
        && lib.hasInfix "$generation/nodes/b" siblingSelection
        && lib.hasInfix "$generation/layers/a" siblingSelection
        && lib.hasInfix "$generation/layers/b" siblingSelection;
      topologyFingerprinted = lib.hasInfix "plan.metadata" siblingScript
        && lib.isDerivation plannerTransitionCheck;
      derivedNodeIds = lib.sort (a: b: a < b) (map (node: node.id) siblingTopology.nodes) == [ "a" "b" "host" ];
      derivedParents = siblingTopology.byId.a.parent == null && siblingTopology.byId.b.parent == null;
    };
  };

  nestedScript = namespaceWithLayers [ (layer "middle" null) (layer "leaf" "middle") ];
  nestedTopology = topologyWithLayers [ (layer "middle" null) (layer "leaf" "middle") ];
  scenarioNested = {
    name = "nested overlay consumes the prepared middle store and metadata";
    checks = {
      middleBeforeLeaf = indexOf "middle-lower" nestedTopology.physical.order
        < indexOf "leaf" nestedTopology.physical.order
        && indexOf "middle-runtime" nestedTopology.physical.order
          < indexOf "leaf" nestedTopology.physical.order;
      leafUsesMiddle = nestedTopology.physical.byId.leaf.parent == "middle-lower"
        && lib.hasInfix "parent_root=\"$(physical_root \"$parent\")/nix/store\"" nestedScript;
      leafHasOwnState = lib.hasInfix ''destination="$stage/nodes/$physical_id"'' materializerSource;
      finalWholeTreeCheck = lib.hasInfix "check_store \"$node_url\" \"$node_root\"" nestedScript
        && lib.hasInfix "unmount_all" nestedScript;
    };
  };

  composedTopology = topologyWithLayers [
    (layer "a" null)
    (layer "b" null)
    (layer "grand" "a")
  ];
  scenarioComposed = {
    name = "composed sibling and nested graph is prepared parent-before-child";
    checks = {
      aBeforeGrand = indexOf "a-lower" composedTopology.physical.order
        < indexOf "grand" composedTopology.physical.order
        && indexOf "a-runtime" composedTopology.physical.order
          < indexOf "grand" composedTopology.physical.order;
      hostBeforeSiblings = indexOf "host-lower" composedTopology.physical.order
        < indexOf "a-lower" composedTopology.physical.order
        && indexOf "host-runtime" composedTopology.physical.order
          < indexOf "b" composedTopology.physical.order;
      grandUsesA = composedTopology.physical.byId.grand.parent == "a-lower";
    };
  };

  promotedTopology = topologyWithLayers [ (layer "b" null) (layer "c" "b") ];
  promotedPhysical = promotedTopology.physical;
  scenarioFirstChildPromotion = {
    name = "first child promotes a logical parent into a frozen lower and runtime continuation";
    checks = {
      frozenRole = promotedPhysical.byId."b-lower".role == "frozen-lower";
      runtimeParent = promotedPhysical.byId."b-runtime".parent == "b-lower";
      childParent = promotedPhysical.byId.c.parent == "b-lower";
      consumerMapping = promotedTopology.consumerNodeByLogical.b == "b-runtime"
        && promotedTopology.consumerNodeByLogical.c == "c";
      frozenMapping = promotedTopology.frozenLowerByLogical.b == "b-lower";
    };
  };

  siblingPromotion = topologyWithLayers [
    (layer "b" null)
    (layer "c" "b")
    (layer "d" "b")
  ];
  scenarioAdditionalSibling = {
    name = "additional siblings reuse the existing frozen lower without another split";
    checks = {
      oneFrozenLower = builtins.length (builtins.filter (node: node.logicalId == "b" && node.role == "frozen-lower") siblingPromotion.physical.nodes) == 1;
      oneContinuation = builtins.length (builtins.filter (node: node.logicalId == "b" && node.role == "runtime" && node.id == "b-runtime") siblingPromotion.physical.nodes) == 1;
      siblingParents = siblingPromotion.physical.byId.c.parent == "b-lower"
        && siblingPromotion.physical.byId.d.parent == "b-lower";
    };
  };

  rebasedPromotion = promotedTopology.rebase {
    viewFingerprints = { b = "b-view-2"; };
  };
  unrelatedTopology = topologyWithLayers [
    (layer "b" null)
    (layer "c" "b")
    (layer "e" null)
  ];
  rebasedUnrelated = unrelatedTopology.rebase {
    viewFingerprints = { b = "b-view-2"; };
  };
  scenarioGenerationRebase = {
    name = "generation rebase changes only dependent frozen lineage and resets the continuation";
    checks = {
      continuationRebased = rebasedPromotion.physical.byId."b-runtime".rebasedFrom == "b-view-2";
      childLineageChanges = rebasedPromotion.lineageByPhysical.c != promotedTopology.lineageByPhysical.c;
      unrelatedLineageStable = rebasedUnrelated.lineageByPhysical.e == unrelatedTopology.lineageByPhysical.e;
      wholeGraphChanges = rebasedUnrelated.generationFingerprint != unrelatedTopology.generationFingerprint;
      unchangedRebaseReuses = (promotedTopology.rebase { }).generationFingerprint == promotedTopology.generationFingerprint;
    };
  };

  removedChild = promotedTopology.rebase {
    logicalNodes = (topologyWithLayers [ (layer "b" null) ]).nodes;
  };
  scenarioRemovalWithoutCollapse = {
    name = "child removal does not collapse the parent's runtime continuation into a live lower";
    checks = {
      splitRetained = removedChild.physical.byId ? "b-lower" && removedChild.physical.byId ? "b-runtime";
      childRemoved = !(removedChild.physical.byId ? c);
      consumerStillContinuation = removedChild.consumerNodeByLogical.b == "b-runtime";
    };
  };

  reparented = unrelatedTopology.rebase {
    logicalNodes = (topologyWithLayers [
      (layer "b" null)
      (layer "c" "b")
      ((layer "e" null) // { parent = "b"; })
    ]).nodes;
  };
  scenarioReparentLineage = {
    name = "reparenting invalidates the moved branch without changing unrelated lineage";
    checks = {
      movedParent = reparented.physical.byId.e.parent == "b-lower";
      movedLineageChanges = reparented.lineageByPhysical.e != unrelatedTopology.lineageByPhysical.e;
      unrelatedStable = reparented.lineageByPhysical.c == unrelatedTopology.lineageByPhysical.c;
      graphFingerprintChanges = reparented.generationFingerprint != unrelatedTopology.generationFingerprint;
    };
  };

  operationSource = topologyWithLayers [ (layer "b" null) (layer "e" null) ];
  addedChild = operationSource.transition {
    targetLogical = (topologyWithLayers [
      (layer "b" null)
      (layer "c" "b")
      (layer "e" null)
    ]).nodes;
    policy = "reconcile";
  };
  movedBranch = addedChild.transition {
    targetLogical = (topologyWithLayers [
      (layer "b" null)
      (layer "c" "b")
      ((layer "e" null) // { parent = "b"; })
    ]).nodes;
    policy = "reconcile";
  };
  removedBranch = movedBranch.transition {
    targetLogical = (topologyWithLayers [
      (layer "b" null)
      (layer "c" "b")
    ]).nodes;
    policy = "reconcile";
  };
  changedStorage = operationSource.transition {
    targetLogical = (topologyWithLayers [
      ((layer "b" null) // { upperDir = "/var/lib/layers/b/new-upper"; })
      ((layer "e" null) // { workDir = "/var/lib/layers/e/new-work"; })
    ]).nodes;
    policy = "reconcile";
  };
  wipedStorage = changedStorage.transition {
    targetLogical = changedStorage.nodes;
    policy = "wipe";
  };
  addedSibling = addedChild.transition {
    targetLogical = (topologyWithLayers [
      (layer "b" null)
      (layer "c" "b")
      (layer "d" "b")
      (layer "e" null)
    ]).nodes;
    policy = "reconcile";
  };
  wipedChild = operationSource.transition {
    targetLogical = addedChild.nodes;
    policy = "wipe";
  };
  descriptorNode = node: {
    inherit (node) id parent upperDir workDir stateDir lowerRoot;
  } // lib.optionalAttrs (node ? containerName) {
    inherit (node) containerName;
  } // lib.optionalAttrs (node ? isSingleton) {
    inherit (node) isSingleton;
  };
  logicalDescriptorFor = nodes: {
    fingerprint = builtins.hashString "sha256" (builtins.toJSON
      (map (node: { inherit (node) id parent; }) nodes));
    order = map (node: node.id) nodes;
    nodes = map descriptorNode nodes;
  };
  graphProjection = transition: {
    inherit (transition) nodes byId order physical consumerNodeByLogical;
    inherit (transition) frozenLowerByLogical lineageByPhysical generationFingerprint;
  };
  transitionProjection = transition: graphProjection transition // {
    inherit (transition) operations dispositions;
  };
  plannerCase = source: target: policy: {
    source = logicalDescriptorFor source.nodes;
    target = logicalDescriptorFor target.nodes;
    sourcePhysical = source.physical.nodes;
    sourceConsumer = source.consumerNodeByLogical;
    sourceExpected = graphProjection source;
    inherit policy;
    expected = transitionProjection target;
  };
  plannerOracleBundle = pkgs.writeText "overlay-transition-oracles.json" (builtins.toJSON {
    cases = {
      add-first-child = plannerCase operationSource addedChild "reconcile";
      add-sibling = plannerCase addedChild addedSibling "reconcile";
      reparent = plannerCase addedChild movedBranch "reconcile";
      remove = plannerCase movedBranch removedBranch "reconcile";
      storage-reset = plannerCase operationSource changedStorage "reconcile";
      wipe = plannerCase operationSource wipedChild "wipe";
    };
  });
  scriptAssignment = name: builtins.head (lib.splitString "\n"
    (builtins.elemAt (lib.splitString "\n${name}=" prepareScript) 1));
  planner = scriptAssignment "planner";
  materializer = scriptAssignment "materializer";
  materializerSource = builtins.readFile materializer;
  plannerTransitionCheck = pkgs.runCommand "overlay-transition-test" {
    inherit plannerOracleBundle planner materializer;
  } ''
    export OVERLAY_PLANNER=$planner
    export OVERLAY_MATERIALIZER=$materializer
    export OVERLAY_NIX_STORE=${pkgs.nix}/bin/nix-store
    export OVERLAY_ORACLE_BUNDLE=$plannerOracleBundle
    ${pkgs.python3}/bin/python3 ${./overlay-nix-transition-test.py}
    touch "$out"
  '';
  physicalIdDescriptor = name: layers: pkgs.writeText "overlay-${name}-physical-id.json" (builtins.toJSON {
    schema = "nixtache.overlay-topology/v1";
    imageId = "nixtache";
    imageVersion = "1";
    lowerDbSha256 = descriptorLowerSha;
    logicalTopology = logicalDescriptorFor ([
      (builtins.head ((cfgOf hostDefault)._topology.nodes))
    ] ++ map (node: { lowerRoot = ""; } // node) layers);
  });
  lowerCollisionDescriptor = physicalIdDescriptor "lower-collision" [
    (layer "b" null)
    (layer "c" "b")
    (layer "b-lower" null)
  ];
  runtimeCollisionDescriptor = physicalIdDescriptor "runtime-collision" [
    (layer "b" null)
    (layer "c" "b")
    (layer "b-runtime" null)
  ];
  physicalIdPrefixDescriptor = physicalIdDescriptor "prefix-only" [
    (layer "b" null)
    (layer "c" "b")
    (layer "b-lower-extra" null)
    (layer "b-runtime-extra" null)
  ];
  physicalIdUnsplitDescriptor = physicalIdDescriptor "unsplit" [
    (layer "b" null)
    (layer "b-lower" null)
    (layer "b-runtime" null)
  ];
  plannerPhysicalIdCheck = pkgs.runCommand "overlay-physical-id-test" {
    inherit planner descriptorLowerSha lowerCollisionDescriptor runtimeCollisionDescriptor;
    inherit physicalIdPrefixDescriptor physicalIdUnsplitDescriptor;
  } ''
    set -euo pipefail
    run_plan() {
      local descriptor=$1
      local directory=$2
      mkdir -p "$directory"
      "$planner" plan \
        --target-descriptor "$descriptor" \
        --image-id nixtache \
        --image-version 1 \
        --lower-sha256 "$descriptorLowerSha" \
        --policy reconcile \
        --initial \
        --output-json "$directory/plan.json" \
        --output-rows "$directory/plan.rows" \
        --output-metadata "$directory/plan.metadata"
    }
    expect_collision() {
      local name=$1
      local physical_id=$2
      local descriptor=$3
      if run_plan "$descriptor" "$name" >"$name.log" 2>&1; then
        echo "physical ID collision unexpectedly passed: $name" >&2
        exit 1
      fi
      if ! grep -F "derived physical node identities must be unique" "$name.log" \
        || ! grep -F "$physical_id" "$name.log"; then
        cat "$name.log" >&2
        exit 1
      fi
      test ! -e "$name/plan.json"
    }
    expect_collision lower b-lower "$lowerCollisionDescriptor"
    expect_collision runtime b-runtime "$runtimeCollisionDescriptor"
    run_plan "$physicalIdPrefixDescriptor" prefix-only
    run_plan "$physicalIdUnsplitDescriptor" unsplit
    test -s prefix-only/plan.json
    test -s unsplit/plan.json
    touch "$out"
  '';
  scenarioPhysicalIdPlannerValidation = {
    name = "planner rejects physical ID collisions before writing plans and accepts noncolliding names";
    checks.rejected = lib.isDerivation plannerPhysicalIdCheck;
  };
  scenarioTransitionOperations = {
    name = "source-to-target transitions preserve eligible branches and classify topology operations";
    checks = {
      addition = addedChild.operations.c == "add";
      firstChildPromotion = addedChild.operations.b == "promote";
      continuationStartsEmpty = addedChild.dispositions."b-runtime" == "empty-continuation";
      unrelatedStateRetained = addedChild.dispositions.e == "clone-and-repair";
      reparent = movedBranch.operations.e == "reparent";
      movedStateRetained = movedBranch.dispositions.e == "clone-and-repair";
      removal = removedBranch.operations.e == "remove";
      storageReset = changedStorage.operations.b == "storage-reset";
      workRewire = changedStorage.operations.e == "rewire";
      storageResetStartsEmpty = changedStorage.dispositions.b == "empty";
      wipeStartsEmpty = wipedStorage.dispositions.b == "empty" && wipedStorage.dispositions.e == "empty";
      wipeKeepsGraph = wipedStorage.generationFingerprint == changedStorage.generationFingerprint;
      wipeOperationKeepsGraph = wipedChild.generationFingerprint == addedChild.generationFingerprint;
      runtimePlannerMatchesAndExecutes = lib.isDerivation plannerTransitionCheck;
      selectionUsesPublishedPhysical = lib.hasInfix ''consumer_generation="$generation/nodes/$physical_id"'' siblingSelection;
      descriptorReadinessAllowsRetainedSplits = (posOf ''if [ -n "$metadata_descriptor" ]; then'' siblingSelection)
        < (posOf ''elif [ -z "$metadata_graph" ]'' siblingSelection);
    };
  };

  runnerOverlayStore = name: parent: {
    store = {
      inherit parent;
      mode = "overlay";
      path = "/srv/${name}";
      hostBackup = "/var/lib/runners/${name}";
    };
  };
  hostFrozenRunners = mkRunnerAppliance {
    services.nixtache.runner.containers = {
      alpha = runnerOverlayStore "alpha" null;
      beta = runnerOverlayStore "beta" "alpha";
      gamma = runnerOverlayStore "gamma" null;
    };
  };
  frozenTopology = (cfgOf hostFrozenRunners)._topology;
  frozenServices = servicesOf hostFrozenRunners;
  frozenSelection = frozenServices.nixtache-overlay-select.script;
  frozenPlanService = frozenServices.nixtache-overlay-frozen;
  hostMountService = frozenServices.nix-daemon-overlay-mount;
  frozenPlanUnit = "nixtache-overlay-frozen.service";
  hostFrozenUnit = "nixtache-overlay-frozen-host-lower.service";
  alphaFrozenUnit = "nixtache-overlay-frozen-alpha-lower.service";
  selectsPlanParent = nodeId:
    lib.hasInfix "parent_physical=$(plan_consumer_parent ${nodeId})" frozenSelection
    && lib.hasInfix "activate_path \"$parent_root\" /run/nixtache-overlay/parents/${nodeId}" frozenSelection;
  scenarioRuntimeFrozenLowers = {
    name = "runtime consumers use selected frozen parents with dedicated state and plan ordering";
    checks = {
      derivedFrozenParents = frozenTopology.frozenParentByLogical.host == "host-lower"
        && frozenTopology.frozenParentByLogical.alpha == "alpha-lower"
        && frozenTopology.frozenParentByLogical.beta == "alpha-lower"
        && frozenTopology.frozenParentByLogical.gamma == "host-lower";
      runtimeContinuationsRetained = frozenTopology.consumerNodeByLogical.host == "host-runtime"
        && frozenTopology.consumerNodeByLogical.alpha == "alpha-runtime"
        && frozenTopology.consumerNodeByLogical.beta == "beta";
      selectedPhysicalUppers = lib.hasInfix ''upper="$generation/nodes/$physical_id/upper"'' frozenPlanService.script
        && lib.hasInfix ''rows="$generation/plan.rows"'' frozenPlanService.script;
      selectedSlotAndGeneration = lib.hasInfix "slot=$(cat /run/nixtache-overlay/selected-slot" frozenPlanService.script
        && lib.hasInfix ''"$(readlink -f "/var/lib/nix-overlay/upper-slots/$slot/current")" = "$generation"'' frozenPlanService.script;
      privateRunWork = lib.hasInfix ''frozen_root="/run/nixtache-overlay/frozen/$physical_id"'' frozenPlanService.script
        && lib.hasInfix ''lowerdir="$upper_dir":"$lower_root",upperdir="$private_upper",workdir="$work_dir" "$store_dir"'' frozenPlanService.script;
      frozenStoresReadOnly = lib.hasInfix ''mount -o remount,ro,bind "$store_dir"'' frozenPlanService.script;
      frozenParentsFirst = lib.hasInfix ''lower_root="/run/nixtache-overlay/frozen/$parent/nix/store"'' frozenPlanService.script
        && lib.hasInfix ''mountpoint -q "$lower_root"'' frozenPlanService.script
        && lib.hasInfix ''done < "$rows"'' frozenPlanService.script
        && (posOf ''mountpoint -q "$lower_root"'' frozenPlanService.script)
          < (posOf ''mount -t overlay overlay'' frozenPlanService.script);
      hostRuntimeUsesFrozenLower = lib.elem frozenPlanUnit hostMountService.after
        && lib.elem frozenPlanUnit hostMountService.requires
        && lib.hasInfix "lowerdir=/run/nixtache-overlay/parents/host/nix/store" hostMountService.script
        && lib.hasInfix "lower-store=local%3Froot%3D/run/nixtache-overlay/parents/host%26state%3D/run/nixtache-overlay/parents/host/nix/var/nix%26read-only%3Dtrue" hostFrozenRunners.config.nix.settings.store;
      readinessRequiresPlanFrozenMounts = lib.all (unit:
        lib.elem unit hostFrozenRunners.config.systemd.targets.nixtache-overlay-ready.after
        && lib.elem unit hostFrozenRunners.config.systemd.targets.nixtache-overlay-ready.requires
      ) [ frozenPlanUnit ]
        && !(lib.elem hostFrozenUnit hostFrozenRunners.config.systemd.targets.nixtache-overlay-ready.requires)
        && !(lib.elem alphaFrozenUnit hostFrozenRunners.config.systemd.targets.nixtache-overlay-ready.requires);
      containersRequireReadinessBoundary = lib.all (name:
        lib.elem "nixtache-overlay-ready.target" frozenServices."container@${name}".requires
        && lib.elem "nixtache-overlay-ready.target" frozenServices."container@${name}".after
        && !(lib.elem hostFrozenUnit frozenServices."container@${name}".requires)
        && !(lib.elem alphaFrozenUnit frozenServices."container@${name}".requires)
      ) [ "alpha" "beta" "gamma" ];
      lowerRootsSelectFrozenMetadata =
        selectsPlanParent "host"
        && selectsPlanParent "alpha"
        && selectsPlanParent "beta"
        && selectsPlanParent "gamma"
        && lib.hasInfix ''activate_frozen_state "$parent_root/nix/var/nix" /run/nixtache-runner-lower/alpha/nix/var/nix'' frozenSelection
        && lib.hasInfix ''activate_frozen_state "$parent_root/nix/var/nix" /run/nixtache-runner-lower/beta/nix/var/nix'' frozenSelection;
      frozenMetadataReadOnlyWithoutCopies =
        lib.hasInfix ''mount -o remount,ro,bind "$target/$name"'' frozenSelection
        && !(lib.hasInfix "cp -a" frozenSelection);
      noRuntimeContinuationLower =
        !(lib.hasInfix ''activate_frozen_state "$consumer_generation/state"'' frozenSelection)
        && !(lib.hasInfix "lower_root=/nix/store" frozenPlanService.script)
        && !(lib.hasInfix "host-runtime/nix/store" hostMountService.script);
      legacyAndEphemeralFallbacksRetained =
        lib.hasInfix ''candidate="$generation/host"'' frozenSelection
        && lib.hasInfix ''candidate="$generation/layers/$logical_id"'' frozenSelection
        && lib.hasInfix "nixtache-overlay-legacy-frozen.rows" frozenPlanService.script
        && lib.hasInfix ''upper="$generation/layers/$logical_id/upper"'' frozenPlanService.script
        && lib.hasInfix "bind_frozen_state" frozenSelection
        && lib.hasInfix "reset_frozen_path" frozenSelection;
      noEvalOnlyFrozenUnits = !(frozenServices ? nixtache-overlay-frozen-host-lower)
        && !(frozenServices ? nixtache-overlay-frozen-alpha-lower);
      nonAbLayoutKeepsLegacyMount =
        lib.hasInfix "lowerdir=/nix/store" (hostWithLayers [ (layer "a" null) ]).config.systemd.services.nix-daemon-overlay-mount.script
        && !((hostWithLayers [ (layer "a" null) ]).config.systemd.services ? nixtache-overlay-frozen);
    };
  };

  retainedLeafRunners = mkRunnerAppliance {
    services.nixtache.runner.containers = {
      alpha = runnerOverlayStore "alpha" null;
    };
  };
  retainedLeafTopology = (cfgOf retainedLeafRunners)._topology;
  retainedLeafSelection = frozenTopology.transition {
    targetLogical = retainedLeafTopology.nodes;
    policy = "reconcile";
  };
  retainedHostRunners = mkRunnerAppliance {
    services.nixtache.runner.enable = lib.mkForce false;
  };
  retainedHostTopology = (cfgOf retainedHostRunners)._topology;
  retainedHostSelection = frozenTopology.transition {
    targetLogical = retainedHostTopology.nodes;
    policy = "reconcile";
  };
  retainedLeafFrozenService = (servicesOf retainedLeafRunners).nixtache-overlay-frozen or { };
  retainedHostFrozenService = (servicesOf retainedHostRunners).nixtache-overlay-frozen or { };
  scenarioRetainedRuntimePlan = {
    name = "selected plans retain split mounts and stable parent roots after target eval collapses to leaves";
    checks = {
      targetEvalCollapses = !(retainedLeafTopology.physical.byId ? "alpha-lower")
        && !(retainedHostTopology.physical.byId ? "host-lower");
      selectedPlanRetainsSplit = retainedLeafSelection.physical.byId ? "alpha-lower"
        && retainedLeafSelection.physical.byId ? "alpha-runtime"
        && retainedHostSelection.physical.byId ? "host-lower"
        && retainedHostSelection.physical.byId ? "host-runtime";
      planMountServiceExistsWithoutEvalRows = retainedLeafFrozenService ? script
        && retainedHostFrozenService ? script;
      planRowsDriveParentFirstMounts = lib.hasInfix ''while IFS='|' read -r physical_id logical_id role parent rest; do'' (retainedLeafFrozenService.script or "")
        && lib.hasInfix ''done < "$rows"'' (retainedLeafFrozenService.script or "")
        && lib.hasInfix ''lower_root="/run/nixtache-overlay/frozen/$parent/nix/store"'' (retainedLeafFrozenService.script or "");
      hostLeafUsesStableLower = lib.hasInfix
        "lower-store=local%3Froot%3D/run/nixtache-overlay/parents/host%26state%3D/run/nixtache-overlay/parents/host/nix/var/nix%26read-only%3Dtrue"
        retainedHostRunners.config.nix.settings.store;
      readinessUsesPlanBoundary = lib.elem "nixtache-overlay-frozen.service"
        retainedHostRunners.config.systemd.targets.nixtache-overlay-ready.requires;
    };
  };

  scenarioDuplicateRejected = {
    name = "duplicate overlay node identities are rejected";
    checks.rejected = !(tryLayers [ (layer "a" null) (layer "a" null) ]).success;
  };
  scenarioPhysicalIdCollisionsRejected = {
    name = "logical IDs colliding with frozen lowers or runtime continuations are rejected";
    checks = {
      frozenLower = !(tryLayers [
        (layer "b" null)
        (layer "c" "b")
        (layer "b-lower" null)
      ]).success;
      runtimeContinuation = !(tryLayers [
        (layer "b" null)
        (layer "c" "b")
        (layer "b-runtime" null)
      ]).success;
    };
  };
  scenarioPhysicalIdBoundariesAllowed = {
    name = "physical ID validation preserves prefix-only and unsplit logical names";
    checks = {
      prefixOnly = (tryLayers [
        (layer "b" null)
        (layer "c" "b")
        (layer "b-lower-extra" null)
        (layer "b-runtime-extra" null)
      ]).success;
      unsplitExactNames = (tryLayers [
        (layer "b" null)
        (layer "b-lower" null)
        (layer "b-runtime" null)
      ]).success;
    };
  };
  scenarioMissingParentRejected = {
    name = "an overlay with a missing parent is rejected";
    checks.rejected = !(tryLayers [ (layer "a" "missing") ]).success;
  };
  scenarioCycleRejected = {
    name = "an overlay parent cycle is rejected";
    checks.rejected = !(tryLayers [ (layer "a" "b") (layer "b" "a") ]).success;
  };

  scenarioPathTraversalIdsRejected = {
    name = "path-traversal overlay node identities are rejected";
    checks = {
      dot = !(tryLayers [ (layer "." null) ]).success;
      dotDot = !(tryLayers [ (layer ".." null) ]).success;
    };
  };

  scenarioWithinNodePathCollisionsRejected = {
    name = "equal and nested runtime paths within one overlay node are rejected";
    checks = {
      equalUpperWork = !(tryLayers [
        ((layer "a" null) // { workDir = "/var/lib/layers/a/upper"; })
      ]).success;
      nestedUpperState = !(tryLayers [
        ((layer "a" null) // { stateDir = "/var/lib/layers/a/upper/state"; })
      ]).success;
      nestedWorkState = !(tryLayers [
        ((layer "a" null) // { stateDir = "/var/lib/layers/a/work/state"; })
      ]).success;
      nestedHostUpperWork = !(tryHost {
        services.nixtache.overlay-nix.workDir = "/var/lib/nix-overlay/upper/work";
      }).success;
    };
  };

  scenarioAcrossNodePathCollisionsRejected = {
    name = "equal and nested runtime paths across overlay nodes are rejected";
    checks = {
      equalUpperWork = !(tryLayers [
        (layer "a" null)
        ((layer "b" null) // { workDir = "/var/lib/layers/a/upper"; })
      ]).success;
      nestedUpperState = !(tryLayers [
        (layer "a" null)
        ((layer "b" null) // { stateDir = "/var/lib/layers/a/upper/state"; })
      ]).success;
      nestedStateWork = !(tryLayers [
        (layer "a" null)
        ((layer "b" null) // { workDir = "/var/lib/layers/a/state/work"; })
      ]).success;
      nestedHostState = !(tryLayers [
        ((layer "a" null) // { stateDir = "/nix/var/nix/layers/a/state"; })
      ]).success;
    };
  };

  scenarioPathPrefixBoundariesAllowed = {
    name = "runtime paths sharing only a string prefix are accepted";
    checks.accepted = (tryLayers [
      ((layer "a" null) // {
        upperDir = "/var/lib/layers/shared/path";
        workDir = "/var/lib/layers/shared/path-work";
        stateDir = "/var/lib/layers/shared/path-state";
      })
      ((layer "b" null) // {
        upperDir = "/var/lib/layers/shared/path-b";
        workDir = "/var/lib/layers/shared/path-work-b";
        stateDir = "/var/lib/layers/shared/path-state-b";
      })
    ]).success;
  };

  hostNone = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "none"; };
  tryNone = builtins.tryEval (builtins.deepSeq (cfgOf hostNone).upperOnUpdate (cfgOf hostNone).upperOnUpdate);
  scenarioNoneRejected = {
    name = "upperOnUpdate = \"none\" is rejected";
    checks.noneRejected = !tryNone.success;
  };

  scenarioCaFeature = {
    name = "daemon config enables the required store features";
    checks = {
      caFeatureOn = builtins.elem "ca-derivations" hostDefault.config.nix.settings.extra-experimental-features;
      readOnlyLowerOn = builtins.elem "read-only-local-store" hostDefault.config.nix.settings.extra-experimental-features;
    };
  };

  scenarios = [
    scenarioDefault
    scenarioReconcile
    scenarioWipe
    scenarioDescriptorValidation
    scenarioPublicLayersRejected
    scenarioSiblings
    scenarioNested
    scenarioComposed
    scenarioFirstChildPromotion
    scenarioAdditionalSibling
    scenarioGenerationRebase
    scenarioRemovalWithoutCollapse
    scenarioReparentLineage
    scenarioPhysicalIdPlannerValidation
    scenarioTransitionOperations
    scenarioRuntimeFrozenLowers
    scenarioRetainedRuntimePlan
    scenarioDuplicateRejected
    scenarioPhysicalIdCollisionsRejected
    scenarioPhysicalIdBoundariesAllowed
    scenarioMissingParentRejected
    scenarioCycleRejected
    scenarioPathTraversalIdsRejected
    scenarioWithinNodePathCollisionsRejected
    scenarioAcrossNodePathCollisionsRejected
    scenarioPathPrefixBoundariesAllowed
    scenarioNoneRejected
    scenarioCaFeature
  ];

  failed = builtins.concatMap
    (s: if builtins.all (c: c) (builtins.attrValues s.checks) then [ ] else [ s.name ])
    scenarios;
  allOk = failed == [ ];
  report = lib.concatStringsSep "\n" (lib.flatten (map
    (s: [ s.name ] ++ (map
      (cn: "  ${if s.checks.${cn} then "ok  " else "FAIL"}  ${cn}")
      (builtins.attrNames s.checks)))
    scenarios));
  failMsg = lib.optionalString (!allOk) "FAILED: ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "overlay-nix-module-test"
  {
    inherit report failMsg;
    deps = [ descriptorValidationCheck plannerTransitionCheck plannerPhysicalIdCheck ];
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

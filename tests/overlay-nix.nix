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
      clonesActiveGeneration = lib.hasInfix "source_dir/host" reconcileScript;
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
      inherit layers;
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
  tryLayers = layers: builtins.tryEval
    (hostWithLayers layers).config.system.build.toplevel.outPath;
  posOf = pat: s: lib.stringLength (builtins.head (lib.splitString pat s));

  siblingScript = scriptWithLayers [ (layer "a" null) (layer "b" null) ];
  siblingNamespace = namespaceWithLayers [ (layer "a" null) (layer "b" null) ];
  siblingSelection = selectWithLayers [ (layer "a" null) (layer "b" null) ];
  scenarioSiblings = {
    name = "sibling overlays share the host parent and one atomic readiness result";
    checks = {
      stagesBoth = lib.hasInfix "$stage/layers/a" siblingScript
        && lib.hasInfix "$stage/layers/b" siblingScript;
      hostFirst = (posOf "repair_store \"$host_url\"" siblingNamespace)
        < (posOf "lower-states/a" siblingNamespace)
        && (posOf "repair_store \"$host_url\"" siblingNamespace)
          < (posOf "lower-states/b" siblingNamespace);
      activatesBoth = lib.hasInfix "$generation/layers/a/upper" siblingSelection
        && lib.hasInfix "$generation/layers/b/upper" siblingSelection;
      topologyFingerprinted = lib.hasInfix "topology_sha256=" siblingScript;
    };
  };

  nestedScript = namespaceWithLayers [ (layer "middle" null) (layer "leaf" "middle") ];
  nestedPrepare = scriptWithLayers [ (layer "middle" null) (layer "leaf" "middle") ];
  scenarioNested = {
    name = "nested overlay consumes the prepared middle store and metadata";
    checks = {
      middleBeforeLeaf = (posOf "lower-states/middle" nestedScript)
        < (posOf "lower-states/leaf" nestedScript);
      leafUsesMiddle = lib.hasInfix "lower-states/middle" nestedScript
        && lib.hasInfix "lowerdir=\"$scratch/layers/middle/nix/store\"" nestedScript;
      leafHasOwnState = lib.hasInfix "$stage/layers/leaf/state" nestedPrepare;
      finalWholeTreeCheck = lib.hasInfix "check_store \"$host_url\" \"$host_root\"" nestedScript
        && lib.hasInfix "check_store \"$node_url\" \"$node_root\"" nestedScript;
    };
  };

  composedScript = namespaceWithLayers [
    (layer "a" null)
    (layer "b" null)
    (layer "grand" "a")
  ];
  scenarioComposed = {
    name = "composed sibling and nested graph is prepared parent-before-child";
    checks = {
      aBeforeGrand = (posOf "lower-states/a" composedScript)
        < (posOf "lower-states/grand" composedScript);
      hostBeforeSiblings = (posOf "repair_store \"$host_url\"" composedScript)
        < (posOf "lower-states/a" composedScript)
        && (posOf "repair_store \"$host_url\"" composedScript)
          < (posOf "lower-states/b" composedScript);
      grandUsesA = lib.hasInfix "lower-states/a" composedScript;
    };
  };

  scenarioDuplicateRejected = {
    name = "duplicate overlay node identities are rejected";
    checks.rejected = !(tryLayers [ (layer "a" null) (layer "a" null) ]).success;
  };
  scenarioMissingParentRejected = {
    name = "an overlay with a missing parent is rejected";
    checks.rejected = !(tryLayers [ (layer "a" "missing") ]).success;
  };
  scenarioCycleRejected = {
    name = "an overlay parent cycle is rejected";
    checks.rejected = !(tryLayers [ (layer "a" "b") (layer "b" "a") ]).success;
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
    scenarioSiblings
    scenarioNested
    scenarioComposed
    scenarioDuplicateRejected
    scenarioMissingParentRejected
    scenarioCycleRejected
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
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

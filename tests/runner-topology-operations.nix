{ nixpkgs
, self
, system ? "x86_64-linux"
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  oracle = import ./runner-topology-oracle.nix { inherit lib; };

  containersFor = state: lib.mapAttrs
    (_: declaration: {
      inherit (declaration) enable containerName;
      store = {
        inherit (declaration) parent mode path hostBackup;
      };
    })
    state;

  mkHost = state: nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.runner
      self.nixosModules.overlay-nix
      ({ lib, ... }: {
        system.stateVersion = lib.trivial.release;
        fileSystems."/" = {
          device = "/dev/sda";
          fsType = "ext4";
        };
        boot.loader.grub.devices = [ "/dev/sda" ];
        services.nixtache.runner = {
          enable = true;
          forgejoUrl = "http://localhost:3000";
          cache.enable = false;
          secrets.cachePrivateKey = /dev/null;
          containers = containersFor state;
        };
        services.nixtache.overlay-nix = {
          enable = true;
          upperOnUpdate = "reconcile";
        };
      })
    ];
  };

  topologyOf = host: host.config.services.nixtache.overlay-nix._topology;
  declarationProjection = topology: oracle.projection (topology // {
    inherit (topology.descriptor) nodes order;
  });

  initialA = {
    untouched = oracle.node "untouched" { };
    stable = oracle.node "stable" { };
    reset = oracle.node "reset" { };
    a = oracle.node "a" { };
    b = oracle.node "b" { };
    move = oracle.node "move" { parent = "a"; };
    moveLeaf = oracle.node "moveLeaf" { parent = "move"; };
  };

  initialB = {
    untouched = oracle.node "untouched" { };
    stable = oracle.node "stable" { };
    left = oracle.node "left" { };
    right = oracle.node "right" { };
    twig = oracle.node "twig" { parent = "right"; };
  };

  traces = [
    {
      name = "breadth-depth-subtree-storage-and-clone";
      initial = initialA;
      checkpoint = 3;
      operations = [
        {
          label = "add a sibling below an existing parent";
          type = "add";
          id = "extra";
          settings.parent = "a";
        }
        {
          label = "add a deeper descendant";
          type = "add";
          id = "deep";
          settings.parent = "moveLeaf";
        }
        {
          label = "reparent a complete subtree";
          type = "reparent";
          id = "move";
          parent = "b";
        }
        {
          label = "reset one branch storage without touching its siblings";
          type = "storage";
          id = "reset";
          changes.hostBackup = "/var/lib/runners/reset-next";
        }
        {
          label = "remove a leaf";
          type = "remove-leaf";
          id = "extra";
        }
        {
          label = "remove an explicit subtree";
          type = "remove-subtree";
          id = "b";
        }
        {
          label = "change an overlay leaf to additive clone mode";
          type = "mode";
          id = "stable";
          mode = "clone";
        }
        {
          label = "restore overlay mode as a fresh overlay node";
          type = "mode";
          id = "stable";
          mode = "overlay";
        }
      ];
    }
    {
      name = "root-placement-native-and-nested-removal";
      initial = initialB;
      checkpoint = 3;
      operations = [
        {
          label = "add an intermediate branch";
          type = "add";
          id = "middle";
          settings.parent = "left";
        }
        {
          label = "add a descendant below the new branch";
          type = "add";
          id = "leaf";
          settings.parent = "middle";
        }
        {
          label = "move a rooted subtree below the new branch";
          type = "reparent";
          id = "right";
          parent = "middle";
        }
        {
          label = "change storage for the original root";
          type = "storage";
          id = "left";
          changes.hostBackup = "/var/lib/runners/left-next";
        }
        {
          label = "remove the deepest leaf";
          type = "remove-leaf";
          id = "leaf";
        }
        {
          label = "switch a leaf to its native store";
          type = "mode";
          id = "stable";
          mode = "overlay";
          path = "/";
        }
        {
          label = "return the native leaf to overlay storage";
          type = "mode";
          id = "stable";
          mode = "overlay";
          path = "/srv/stable";
        }
        {
          label = "remove the moved subtree through its explicit root";
          type = "remove-subtree";
          id = "middle";
        }
      ];
    }
  ];

  evaluateTrace = trace:
    let
      models = oracle.modelsFor trace.initial trace.operations;
      hosts = map mkHost models;
      operationLabels = [ "initial declaration" ] ++ map (operation: operation.label) trace.operations;
      walk = index: previousActual: previousExpected:
        if index == builtins.length models then
          [ ]
        else
          let
            state = builtins.elemAt models index;
            host = builtins.elemAt hosts index;
            topology = topologyOf host;
            expectedDirect = oracle.derive { inherit state; };
            initialStep = index == 0;
            actual = if initialStep then topology else previousActual.transition {
              targetLogical = topology.nodes;
              policy = "reconcile";
            };
            expected = if initialStep then expectedDirect else oracle.transition {
              sourceState = builtins.elemAt models (index - 1);
              targetState = state;
              previousPhysical = previousExpected.physical.nodes;
              policy = "reconcile";
            };
            actualWipe = if initialStep then null else previousActual.transition {
              targetLogical = topology.nodes;
              policy = "wipe";
            };
            expectedWipe = if initialStep then null else oracle.transition {
              sourceState = builtins.elemAt models (index - 1);
              targetState = state;
              previousPhysical = previousExpected.physical.nodes;
              policy = "wipe";
            };
            step = {
              name = "${trace.name}: ${builtins.elemAt operationLabels index}";
              inherit state topology actual expected;
              checks = {
                validDeclarations = builtins.all (assertion: assertion.assertion) host.config.assertions;
                declarationGraphMatchesOracle = declarationProjection topology
                  == oracle.projection expectedDirect;
                transitionMatchesOracle = (if initialStep then declarationProjection topology
                  else oracle.projection actual) == oracle.projection expected;
                unchangedLineage = initialStep
                  || actual.lineageByPhysical.untouched == previousActual.lineageByPhysical.untouched;
                wipeMatchesOracle = initialStep
                  || oracle.projection actualWipe == oracle.projection expectedWipe;
                wipeConvergesToSameGraph = initialStep
                  || oracle.graphProjection actualWipe == oracle.graphProjection actual;
                wipeLeavesEveryWritableNodeEmpty = initialStep || builtins.all
                  (node: node.role == "frozen-lower"
                    || actualWipe.dispositions.${node.id} == "empty")
                  actualWipe.physical.nodes;
              };
            };
          in
          [ step ] ++ walk (index + 1) actual expected;
      history = walk 0 null null;
      steps = map (step: { inherit (step) name checks; }) history;
      finalStep = lib.last history;
      reverseAt = index:
        let
          targetStep = builtins.elemAt history index;
        in
        {
          inherit targetStep;
          actual = finalStep.actual.transition {
            targetLogical = targetStep.topology.nodes;
            policy = "reconcile";
          };
          expected = oracle.transition {
            sourceState = finalStep.state;
            targetState = targetStep.state;
            previousPhysical = finalStep.expected.physical.nodes;
            policy = "reconcile";
          };
        };
      initialReverse = reverseAt 0;
      checkpointReverse = reverseAt trace.checkpoint;
      allReverses = map reverseAt (lib.range 0 (builtins.length history - 1));
      reverseMatchesOracle = reverse: oracle.projection reverse.actual == oracle.projection reverse.expected;
      reverseMatchesHistory = reverse:
        { inherit (reverse.actual) nodes order; }
        == { inherit (reverse.targetStep.topology.descriptor) nodes order; };
      reversePreservesUntouched = reverse: reverse.actual.lineageByPhysical.untouched
        == finalStep.actual.lineageByPhysical.untouched;
      replayedCheckpoint = topologyOf (mkHost (builtins.elemAt models trace.checkpoint));
      replayedInitial = topologyOf (mkHost trace.initial);
    in
    {
      inherit steps;
      replay = {
        name = "${trace.name}: declaration replay is deterministic";
        checks = {
          initialDeclarationReplayDeterministic = declarationProjection replayedInitial
            == declarationProjection (builtins.head history).actual;
          intermediateDeclarationReplayDeterministic = declarationProjection replayedCheckpoint
            == declarationProjection (builtins.elemAt history trace.checkpoint).topology;
        };
      };
      rollback = {
        name = "${trace.name}: reverse transitions match the oracle and retained logical history";
        checks = {
          initialReverseMatchesOracle = reverseMatchesOracle initialReverse;
          initialReverseLogicalGraphMatchesHistory = reverseMatchesHistory initialReverse;
          initialReversePreservesUntouchedLineage = reversePreservesUntouched initialReverse;
          intermediateReverseMatchesOracle = reverseMatchesOracle checkpointReverse;
          intermediateReverseLogicalGraphMatchesHistory = reverseMatchesHistory checkpointReverse;
          intermediateReversePreservesUntouchedLineage = reversePreservesUntouched checkpointReverse;
        };
      };
      rollbackEveryStep = map (reverse: {
        name = "${trace.name}: rollback restores ${reverse.targetStep.name}";
        checks = {
          reverseMatchesOracle = reverseMatchesOracle reverse;
          reverseLogicalGraphMatchesHistory = reverseMatchesHistory reverse;
          reversePreservesUntouchedLineage = reversePreservesUntouched reverse;
        };
      }) allReverses;
    };

  evaluatedTraces = map evaluateTrace traces;

  invalidBase = initialA;
  invalidSelf = invalidBase // {
    a = invalidBase.a // { parent = "a"; };
  };
  invalidCycle = invalidBase // {
    a = invalidBase.a // { parent = "b"; };
    b = invalidBase.b // { parent = "a"; };
  };
  invalidOrphanedRemoval = removeAttrs invalidBase [ "a" ];
  invalidCloneParent = invalidBase // {
    a = invalidBase.a // { mode = "clone"; };
  };
  invalidNativeParent = invalidBase // {
    a = invalidBase.a // { path = "/"; };
  };

  tryHost = state:
    let
      host = mkHost state;
      valid = builtins.all (assertion: assertion.assertion) host.config.assertions;
    in
    builtins.tryEval (lib.assertMsg valid "runner topology assertions failed"
      (topologyOf host).generationFingerprint);

  invalidScenario = {
    name = "invalid operations leave no evaluable replacement graph";
    checks = {
      selfReparentRejected = !(tryHost invalidSelf).success;
      cycleRejected = !(tryHost invalidCycle).success;
      orphanedRemovalRejected = !(tryHost invalidOrphanedRemoval).success;
      cloneParentRejected = !(tryHost invalidCloneParent).success;
      nativeParentRejected = !(tryHost invalidNativeParent).success;
    };
  };

  scenarios = lib.concatMap (trace: trace.steps) evaluatedTraces
    ++ map (trace: trace.replay) evaluatedTraces
    ++ map (trace: trace.rollback) evaluatedTraces
    ++ lib.concatMap (trace: trace.rollbackEveryStep) evaluatedTraces
    ++ [ invalidScenario ];

  failed = lib.concatMap
    (scenario:
      if builtins.all (check: check) (builtins.attrValues scenario.checks) then
        [ ]
      else
        [ scenario.name ])
    scenarios;

  report = lib.concatStringsSep "\n" (lib.flatten (map
    (scenario:
      [ scenario.name ] ++ map
        (name: "  ${if scenario.checks.${name} then "ok  " else "FAIL"}  ${name}")
        (builtins.attrNames scenario.checks))
    scenarios));

  failMsg = lib.optionalString (failed != [ ])
    "FAILED: ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "runner-topology-operations-test"
{
  inherit report failMsg;
  passAsFile = [ "report" "failMsg" ];
}
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then
      cat "$failMsgPath"
      printf '\n%s\n' "$(<"$failMsgPath")" >> "$out"
      exit 1
    fi
  ''

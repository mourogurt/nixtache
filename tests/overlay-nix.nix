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

  migration = import ../modules/overlay-nix/migration.nix { inherit pkgs; };
  migrationCheck = pkgs.runCommand "overlay-nix-migration-test" { } ''
    set -euo pipefail
    ${migration.rollbackActivationSnippet}
    ${migration.activatePathSnippet}

    fail_copy=0
    corrupt_copy=0
    force_exdev=0
    cp() {
      local destination
      for destination; do :; done
      if [ "$fail_copy" = 1 ]; then
        mkdir -p "$destination"
        printf 'partial\n' > "$destination/partial"
        return 1
      fi
      if [ "$corrupt_copy" = 1 ]; then
        command cp "$@" || return 1
        rm -f -- "$destination/keep"
        return 0
      fi
      command cp "$@"
    }
    stat() {
      local path
      if [ "$force_exdev" = 1 ]; then
        for path; do :; done
        case "$path" in
          */backup-parent) printf '2\n'; return 0 ;;
          */link) printf '1\n'; return 0 ;;
        esac
      fi
      command stat "$@"
    }
    new_case() {
      case_dir="$PWD/$1"
      source="$case_dir/source"
      link="$case_dir/link"
      backup="$case_dir/backup-parent/legacy"
      activation_log="$case_dir/activation.log"
      mkdir -p "$source" "$link" "$(dirname "$backup")"
      printf 'selected\n' > "$source/selected"
      printf 'legacy\n' > "$link/keep"
      ln -s keep "$link/root"
      : > "$activation_log"
    }

    new_case same-filesystem
    activate_path "$source" "$link" "$backup"
    test "$(readlink "$link")" = "$source"
    test "$(cat "$backup/keep")" = legacy
    grep -Fx "M|$link|$backup" "$activation_log"
    test ! -e "$backup.migration-ready"

    new_case copy-interruption
    force_exdev=1
    fail_copy=1
    if activate_path "$source" "$link" "$backup"; then
      echo "interrupted copy unexpectedly activated the selected path" >&2
      exit 1
    fi
    fail_copy=0
    test "$(cat "$link/keep")" = legacy
    test ! -e "$backup"
    if grep -q '^M|' "$activation_log"; then
      echo "interrupted copy was journaled as migrated" >&2
      exit 1
    fi
    activate_path "$source" "$link" "$backup"
    test "$(readlink "$link")" = "$source"
    test "$(cat "$backup/keep")" = legacy
    test "$(readlink "$backup/root")" = keep
    test -e "$backup.migration-ready"

    new_case copy-verification
    corrupt_copy=1
    if activate_path "$source" "$link" "$backup"; then
      echo "incomplete temporary copy was published as a verified backup" >&2
      exit 1
    fi
    corrupt_copy=0
    test "$(cat "$link/keep")" = legacy
    test ! -e "$backup"
    if grep -q '^M|' "$activation_log"; then
      echo "unverified temporary copy was journaled as migrated" >&2
      exit 1
    fi

    new_case incomplete-backup
    mkdir -p "$backup"
    printf 'incomplete\n' > "$backup/partial"
    if activate_path "$source" "$link" "$backup"; then
      echo "incomplete existing backup displaced the legacy source" >&2
      exit 1
    fi
    test "$(cat "$link/keep")" = legacy
    test ! -L "$link"
    if grep -q '^M|' "$activation_log"; then
      echo "incomplete existing backup was journaled as migrated" >&2
      exit 1
    fi

    new_case unlink-interruption
    cleanup_definition=$(declare -f remove_migrated_source)
    remove_migrated_source() { return 1; }
    if activate_path "$source" "$link" "$backup"; then
      echo "interrupted source cleanup unexpectedly activated the selected path" >&2
      exit 1
    fi
    eval "$cleanup_definition"
    test "$(cat "$link/keep")" = legacy
    test "$(cat "$backup/keep")" = legacy
    test -e "$backup.migration-ready"
    grep -Fx "M|$link|$backup" "$activation_log"
    : > "$activation_log"
    activate_path "$source" "$link" "$backup"
    test "$(readlink "$link")" = "$source"
    test "$(cat "$backup/keep")" = legacy
    grep -Fx "M|$link|$backup" "$activation_log"

    touch "$out"
  '';

  scenarioMigration = {
    name = "cross-filesystem migration publishes verified backups before journaling and source cleanup";
    checks = {
      transactionalRecovery = lib.isDerivation migrationCheck;
      sameFilesystemMoveRetained = lib.hasInfix ''if ! mv "$link" "$backup"; then'' selectScript;
      copyFaultAnchorRetained = lib.hasInfix ''if ! cp -a -- "$link" "$temporary"; then'' selectScript;
      unlinkFaultAnchorRetained = lib.hasInfix "remove_migrated_source() {\n  local link=$1" selectScript;
      stateSourceNotDeletedBeforeVerification = !(lib.hasInfix ''if [ -d "$link" ] && [ ! -L "$link" ] && [ -e "$backup" ]; then'' selectScript);
    };
  };

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
  quiesceRecoveryCheck = pkgs.runCommand "overlay-nix-quiesce-recovery-test" {
    inherit reconcileScript;
    passAsFile = [ "reconcileScript" ];
  } ''
    set -euo pipefail
    awk '
      /^[[:space:]]*resume_writers\(\) \{/ { copy = 1 }
      copy { print }
      copy && /^[[:space:]]*\}/ { exit }
    ' "$reconcileScriptPath" > resume.sh
    awk '
      /^[[:space:]]*for unit in .*nix-daemon\.service nix-daemon\.socket; do$/ { copy = 1 }
      copy { print }
      copy && /^[[:space:]]*done$/ { exit }
    ' "$reconcileScriptPath" > quiesce.sh
    grep -q '^resume_writers()' resume.sh
    grep -q 'systemctl stop' quiesce.sh
    events=$PWD/events
    : > "$events"
    systemctl() {
      local action=$1 unit=''${2:-}
      printf '%s %s\n' "$action" "$unit" >> "$events"
      if [ "$action" = is-active ]; then return 0; fi
      if [ "$action" = stop ] && [ "$unit" = nix-daemon.socket ]; then return 1; fi
      return 0
    }
    set +e
    (
      set -euo pipefail
      quiesced=0
      stopped_units=""
      source ./resume.sh
      trap resume_writers EXIT
      source ./quiesce.sh
    )
    quiesce_status=$?
    set -e
    if [ "$quiesce_status" = 0 ]; then
      echo "quiesce unexpectedly ignored a writer stop failure" >&2
      exit 1
    fi
    grep -Fx 'stop nix-daemon.service' "$events"
    grep -Fx 'start nix-daemon.service' "$events"
    if grep -Fq 'start nix-daemon.socket' "$events"; then
      echo "a writer that failed to stop was incorrectly resumed" >&2
      exit 1
    fi
    : > "$events"
    systemctl() {
      local action=$1 unit=''${2:-}
      printf '%s %s\n' "$action" "$unit" >> "$events"
      if [ "$action" = start ] && [ "$unit" = nix-daemon.service ]; then return 1; fi
      return 0
    }
    set +e
    (
      set -euo pipefail
      stopped_units=nix-daemon.service
      source ./resume.sh
      trap 'resume_writers || true' EXIT
      resume_writers
    )
    resume_status=$?
    set -e
    if [ "$resume_status" = 0 ]; then
      echo "writer restart failure was ignored" >&2
      exit 1
    fi
    [ "$(grep -c '^start nix-daemon.service$' "$events")" = 2 ]
    touch "$out"
  '';
  scenarioReconcile = {
    name = "reconcile clones a ready active generation and resumes writers before target repair";
    checks = {
      valueIsReconcile = (cfgOf hostReconcile).upperOnUpdate == "reconcile";
      clonesActiveGeneration = lib.hasInfix ''"$materializer" "$stage/plan.rows" "$source_dir" "$stage"'' reconcileScript;
      quiescesWriters = lib.hasInfix "nix-daemon.socket" reconcileScript;
      failedStopResumesStoppedWriters = lib.isDerivation quiesceRecoveryCheck;
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
  readinessCheck = pkgs.runCommand "overlay-nix-readiness-test" {
    selectionText = selectScript;
    inherit validDescriptor descriptorLowerSha;
    topologyFingerprint = (cfgOf hostDefault)._topology.fingerprint;
    passAsFile = [ "selectionText" ];
  } ''
    set -euo pipefail
    sed -n '/^[[:space:]]*metadata_value() {/,/^[[:space:]]*}/p' "$selectionTextPath" > readiness.sh
    sed -n '/^[[:space:]]*ready_generation() {/,/^[[:space:]]*}/p' "$selectionTextPath" >> readiness.sh
    grep -q 'ready_generation()' readiness.sh
    sed -i \
      -e "s#/var/lib/nix-overlay/upper-slots#$PWD/slots#g" \
      -e "s#/etc/image-version#$PWD/image-version#g" \
      -e "s#/run/booted-system#$PWD/booted-system#g" \
      readiness.sh
    generation=$PWD/slots/slot-a/generations/ready
    mkdir -p "$generation"
    printf '%s\n' /nix/store/nixtache-test-system 'source lower' > "$generation/lower-db"
    ln -s /nix/store/nixtache-test-system booted-system
    cp "$generation/lower-db" lower-db.valid
    lower_sha=$(sha256sum "$generation/lower-db" | awk '{print $1}')
    sed "s/$descriptorLowerSha/$lower_sha/g" "$validDescriptor" > "$generation/overlay-topology.json"
    cp "$generation/overlay-topology.json" descriptor.valid
    descriptor_sha=$(sha256sum "$generation/overlay-topology.json" | awk '{print $1}')
    cat > "$generation/metadata" <<EOF
    slot=slot-a
    state=ready
    image_id=nixtache
    image_version=1
    topology_sha256=$topologyFingerprint
    descriptor_sha256=$descriptor_sha
    lower_sha256=$lower_sha
    EOF
    ln -s generations/ready slots/slot-a/current
    printf '1\n' > image-version
    source ./readiness.sh
    test "$(ready_generation slot-a)" = "$generation"

    printf '2\n' > image-version
    if ready_generation slot-a >/dev/null; then
      echo "readiness accepted a generation from a different boot version" >&2
      exit 1
    fi
    printf '1\n' > image-version

    sed 's/"imageVersion":"1"/"imageVersion":"2"/' descriptor.valid > "$generation/overlay-topology.json"
    descriptor_sha=$(sha256sum "$generation/overlay-topology.json" | awk '{print $1}')
    sed -i "s/^descriptor_sha256=.*/descriptor_sha256=$descriptor_sha/" "$generation/metadata"
    if ready_generation slot-a >/dev/null; then
      echo "readiness accepted an owned descriptor from a different installation" >&2
      exit 1
    fi
    cp descriptor.valid "$generation/overlay-topology.json"
    descriptor_sha=$(sha256sum "$generation/overlay-topology.json" | awk '{print $1}')
    sed -i "s/^descriptor_sha256=.*/descriptor_sha256=$descriptor_sha/" "$generation/metadata"

    printf '%s\n' /nix/store/nixtache-test-system 'stale lower' > "$generation/lower-db"
    lower_sha=$(sha256sum "$generation/lower-db" | awk '{print $1}')
    sed -i "s/^lower_sha256=.*/lower_sha256=$lower_sha/" "$generation/metadata"
    if ready_generation slot-a >/dev/null; then
      echo "readiness accepted a lower dump inconsistent with its owned descriptor" >&2
      exit 1
    fi
    cp lower-db.valid "$generation/lower-db"
    lower_sha=$(sha256sum "$generation/lower-db" | awk '{print $1}')
    sed -i "s/^lower_sha256=.*/lower_sha256=$lower_sha/" "$generation/metadata"

    ln -sfn /nix/store/nixtache-different-system booted-system
    if ready_generation slot-a >/dev/null; then
      echo "readiness accepted a generation that does not own the booted toplevel registration" >&2
      exit 1
    fi
    ln -sfn /nix/store/nixtache-test-system booted-system
    test "$(ready_generation slot-a)" = "$generation"
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
      parentsRecheckedAfterChildren = lib.hasInfix "physical_is_parent" nestedScript
        && lib.hasInfix "check_store \"$parent_url\" \"$parent_merged_root\"" nestedScript
        && (posOf "nixtache-overlay: rechecking parent" nestedScript)
          > (posOf "check_store \"$node_url\" \"$node_root\"" nestedScript);
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
  storageModeLayers = [
    ((layer "b" null) // {
      upperDir = "/tmp/nix-overlay-b/upper";
      workDir = "/tmp/nix-overlay-b/work";
    })
    (layer "c" "b")
    (layer "e" null)
  ];
  mkStorageModeHost = ephemeral: mkHost {
    services.nixtache.overlay-nix = {
      _layers = storageModeLayers;
      upperOnUpdate = "reconcile";
    };
    fileSystems = {
      "/" = {
        device = "/dev/sda";
        fsType = "ext4";
      };
    } // lib.optionalAttrs ephemeral {
      "/tmp/nix-overlay-b" = {
        device = "tmpfs";
        fsType = "tmpfs";
      };
    };
  };
  storageModeSourceTopology = (cfgOf (mkStorageModeHost false))._topology;
  storageModeEphemeralTopology = (cfgOf (mkStorageModeHost true))._topology;
  persistentToEphemeral = storageModeSourceTopology.transition {
    targetLogical = storageModeEphemeralTopology.descriptor.nodes;
    policy = "reconcile";
  };
  ephemeralToPersistent = storageModeEphemeralTopology.transition {
    targetLogical = storageModeSourceTopology.descriptor.nodes;
    policy = "reconcile";
  };
  wholeEphemeralTopology = (cfgOf (mkHost {
    services.nixtache.overlay-nix = {
      _layers = storageModeLayers;
      upperOnUpdate = "reconcile";
    };
    fileSystems = {
      "/" = {
        device = "/dev/sda";
        fsType = "ext4";
      };
      "/var/lib/nix-overlay/upper" = {
        device = "tmpfs";
        fsType = "tmpfs";
      };
    };
  }))._topology;
  wholeEphemeralToPersistent = wholeEphemeralTopology.transition {
    targetLogical = storageModeSourceTopology.descriptor.nodes;
    policy = "reconcile";
  };
  persistentToWholeEphemeral = storageModeSourceTopology.transition {
    targetLogical = wholeEphemeralTopology.descriptor.nodes;
    policy = "reconcile";
  };
  storageModeTargetById = lib.listToAttrs (map
    (node: lib.nameValuePair node.id node)
    storageModeEphemeralTopology.descriptor.nodes);
  descriptorNode = node: {
    inherit (node) id parent upperDir workDir stateDir lowerRoot;
  } // lib.optionalAttrs (node ? ephemeral) {
    inherit (node) ephemeral;
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
    source = source.descriptor or (logicalDescriptorFor source.nodes);
    target = target.descriptor or (logicalDescriptorFor target.nodes);
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
      persistent-to-ephemeral = plannerCase storageModeSourceTopology persistentToEphemeral "reconcile";
      ephemeral-to-persistent = plannerCase storageModeEphemeralTopology ephemeralToPersistent "reconcile";
      whole-ephemeral-to-persistent = plannerCase wholeEphemeralTopology wholeEphemeralToPersistent "reconcile";
      persistent-to-whole-ephemeral = plannerCase storageModeSourceTopology persistentToWholeEphemeral "reconcile";
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
  scenarioStorageModeTransitions = {
    name = "target-declared tmpfs modes reset and filter exactly their physical subtrees in both transition directions";
    checks = {
      sourceModesSerialized = builtins.all
        (node: !(node.ephemeral or false))
        storageModeSourceTopology.descriptor.nodes;
      ancestorTmpfsAndLogicalDescendantsSerialized = !(storageModeTargetById.host.ephemeral or false)
        && (storageModeTargetById.b.ephemeral or false)
        && (storageModeTargetById.c.ephemeral or false)
        && !(storageModeTargetById.e.ephemeral or false);
      physicalDescendantsInheritTargetMode =
        (persistentToEphemeral.physical.byId."b-lower".ephemeral or false)
        && (persistentToEphemeral.physical.byId."b-runtime".ephemeral or false)
        && (persistentToEphemeral.physical.byId.c.ephemeral or false)
        && !(persistentToEphemeral.physical.byId.e ? ephemeral);
      persistentToEphemeralOperations = persistentToEphemeral.operations.b == "storage-reset"
        && persistentToEphemeral.operations.c == "storage-reset"
        && persistentToEphemeral.operations.e == "unchanged";
      ephemeralToPersistentOperations = ephemeralToPersistent.operations.b == "storage-reset"
        && ephemeralToPersistent.operations.c == "storage-reset"
        && ephemeralToPersistent.operations.e == "unchanged";
      fingerprintsReflectBothDirections =
        persistentToEphemeral.generationFingerprint != storageModeSourceTopology.generationFingerprint
        && ephemeralToPersistent.generationFingerprint != storageModeEphemeralTopology.generationFingerprint;
      wholeEphemeralSourceResetsEveryPersistentTarget = builtins.all
        (node: node.ephemeral or false)
        wholeEphemeralTopology.descriptor.nodes
        && builtins.all
          (operation: operation == "storage-reset")
          (builtins.attrValues wholeEphemeralToPersistent.operations);
      wholeEphemeralTargetHasNoPersistentRows = builtins.all
        (node: node.ephemeral or false)
        persistentToWholeEphemeral.physical.nodes;
      preparationGatesEphemeralSuccessOnTargetRows = lib.hasInfix
        ''if ! grep -q '|0$' "$probe/plan.rows"; then''
        prepareScript
        && (posOf ''if ! grep -q '|0$' "$probe/plan.rows"; then'' prepareScript)
          < (posOf ''mkdir -p "$slot_dir"'' prepareScript);
      ephemeralSourceUsesDescriptorWithoutSourceRoot = lib.hasInfix
        ''plan_args+=(--source-descriptor'' prepareScript
        && lib.hasInfix ''[ "$source_ephemeral" != 1 ] && [ -n "$source_slot" ]'' prepareScript;
      materializerUsesTargetRows = !(lib.hasInfix "findmnt -T" materializerSource)
        && lib.hasInfix "target_ephemeral" materializerSource;
      ephemeralSourceNeverAdoptsPersistentCurrent = lib.hasInfix
        ''if [ "$source_ephemeral" = 0 ] && [ -n "$current_before" ]'' prepareScript;
      recoverySkipsIncompleteMetadata = lib.hasInfix
        ''source_slot=$(metadata_value "$candidate/metadata" source_slot || true)'' prepareScript
        && lib.hasInfix
          ''source_generation=$(metadata_value "$candidate/metadata" source_generation || true)'' prepareScript;
      plannerAndMaterializerCoverBothDirections = lib.isDerivation plannerTransitionCheck;
    };
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
      frozenReadinessIsStrict = lib.hasPrefix "set -euo pipefail\n" frozenPlanService.script
        && lib.hasInfix ''if [ "$published_plan" = 1 ] && ! grep -q "^$physical_id|" "$generation/persistent-plan.rows"; then'' frozenPlanService.script
        && lib.hasInfix ''if mountpoint -q "$store_dir"; then'' frozenPlanService.script
        && lib.hasInfix ''mountpoint -q "$lower_root"'' frozenPlanService.script;
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
        && !(lib.hasInfix ''cp -a "$source'' frozenSelection)
        && !(lib.hasInfix ''cp -a -- "$source'' frozenSelection);
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

  scenarioGenerationArtifactIdentity = {
    name = "prepared generations own their physical lower identity and recovery ignores stale source records";
    checks = {
      tmpfsRecordsBootedSlot = (posOf ''slot=$(discover_booted)'' selectScript)
        < (posOf ''reset_dir /var/lib/nix-overlay/lower-state'' selectScript)
        && (posOf ''printf '%s\n' "$slot" > /run/nixtache-overlay/selected-slot'' selectScript)
          < (posOf ''reset_dir /var/lib/nix-overlay/lower-state'' selectScript);
      discoveryUsesPreservedPhysicalLower = lib.hasInfix
        "findmnt -n -o SOURCE --target /run/nixtache-overlay/physical-host/nix/store"
        prepareScript
        && !(lib.hasInfix "findmnt -n -o SOURCE --target /nix/store" prepareScript)
        && lib.hasInfix "mount --bind /run/nixtache-overlay/physical-host/nix/store \"$lower_store\"" (namespaceWithLayers [ ])
        && !(lib.hasInfix "mount --bind /nix/store \"$lower_store\"" (namespaceWithLayers [ ]));
      lowerDumpPublished = lib.hasInfix ''cp "$target_dump" "$stage/lower-db"'' prepareScript;
      descriptorPublished = lib.hasInfix ''cp "$target_descriptor" "$stage/overlay-topology.json"'' prepareScript;
      readinessUsesGenerationCopies = lib.hasInfix ''current_descriptor="$generation/overlay-topology.json"'' prepareScript
        && lib.hasInfix ''current_dump="$generation/lower-db"'' prepareScript
        && !(lib.hasInfix ''current_descriptor="/boot/EFI/'' prepareScript)
        && !(lib.hasInfix ''current_dump="/boot/EFI/'' prepareScript);
      readinessRejectsStaleBootArtifacts = lib.isDerivation readinessCheck
        && lib.hasInfix ''[ "$(metadata_value "$metadata" image_version)" = "$image_version" ]'' selectScript
        && lib.hasInfix ''grep -Fqx -- "$booted_system" "$current_dump"'' selectScript
        && lib.hasInfix ''"$current_descriptor" "$image_version" "$dump_sha"'' selectScript;
      targetReuseChecksBootIdentity = lib.hasInfix
        ''[ "$(metadata_value "$current_before/metadata" image_version)" = "$target_version" ]''
        prepareScript
        && lib.hasInfix
          ''[ "$(metadata_value "$current_before/metadata" image_id)" = nixtache ]''
          prepareScript;
      selectionUsesGenerationCopies = lib.hasInfix ''generation=$(ready_generation "$slot" || true)'' selectScript
        && !(lib.hasInfix "/boot/EFI/nixtache" selectScript);
      lowerLoaderUsesGenerationCopy = lib.hasInfix ''dump="$selected_generation/lower-db"''
        frozenServices.nixtache-lower-store-db-load.script;
      targetDescriptorValidationRetained = lib.hasInfix
        ''"$descriptor_validator" "$target_descriptor" "$target_version" "$lower_sha"''
        prepareScript;
      targetReuseChecksGenerationCopies = lib.hasInfix
        ''[ "$lower_sha" = "$(sha256sum "$current_before/lower-db" | awk '{print $1}')" ]''
        prepareScript
        && lib.hasInfix
          ''[ "$descriptor_sha" = "$(sha256sum "$current_before/overlay-topology.json" | awk '{print $1}')" ]''
          prepareScript;
      staleRecordedSourceIgnored = lib.hasInfix
        ''[ "$(metadata_value "$source_dir/metadata" state)" = ready ]''
        prepareScript
        && lib.hasInfix ''source_dir=$(readlink -f "/var/lib/nix-overlay/upper-slots/$source_slot/generations/$source_generation"'' prepareScript
        && lib.hasInfix ''source_slot=""'' prepareScript
        && lib.hasInfix ''source_generation=""'' prepareScript;
      fallbackUsesOtherCurrentReadyGeneration = lib.hasInfix
        ''source_generation=$(basename "$generation")''
        prepareScript
        && lib.hasInfix ''[ "$(metadata_value "$generation/metadata" state)" = ready ]'' prepareScript;
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
    scenarioMigration
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
    scenarioStorageModeTransitions
    scenarioTransitionOperations
    scenarioRuntimeFrozenLowers
    scenarioGenerationArtifactIdentity
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
    deps = [ descriptorValidationCheck plannerTransitionCheck plannerPhysicalIdCheck migrationCheck quiesceRecoveryCheck readinessCheck ];
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

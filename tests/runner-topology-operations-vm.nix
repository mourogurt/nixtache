{ nixpkgs
, self
, system ? "x86_64-linux"
, policy ? "reconcile"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  fixture = import ./runner-topology-vm-lib.nix {
    inherit nixpkgs self system appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib oracle;
  sourceState = {
    stable = oracle.node "stable" { };
    reset = oracle.node "reset" { };
    a = oracle.node "a" { };
    b = oracle.node "b" { };
    move = oracle.node "move" { parent = "a"; };
    moveLeaf = oracle.node "moveLeaf" { parent = "move"; };
    removeRoot = oracle.node "removeRoot" { };
    removeChild = oracle.node "removeChild" { parent = "removeRoot"; };
  };
  operations = [
    {
      type = "add";
      id = "addSibling";
      settings.parent = "b";
    }
    {
      type = "add";
      id = "addDeep";
      settings.parent = "moveLeaf";
    }
    {
      type = "reparent";
      id = "move";
      parent = "b";
    }
    {
      type = "storage";
      id = "reset";
      changes.hostBackup = "/var/lib/runners/reset-next";
    }
    {
      type = "remove-leaf";
      id = "removeChild";
    }
    {
      type = "remove-subtree";
      id = "removeRoot";
    }
  ];
  operationState = lib.foldl' oracle.applyOperation sourceState operations;
  cloneState = oracle.applyOperation operationState {
    type = "mode";
    id = "stable";
    mode = "clone";
  };
  targetState = oracle.applyOperation cloneState {
    type = "mode";
    id = "stable";
    mode = "overlay";
  };
  sourceDirect = oracle.derive { state = sourceState; };
  sourceExpected = oracle.transition {
    inherit sourceState;
    targetState = sourceState;
    previousPhysical = sourceDirect.physical.nodes;
    inherit policy;
  };
  cloneExpected = oracle.transition {
    inherit sourceState policy;
    targetState = cloneState;
    previousPhysical = sourceDirect.physical.nodes;
  };
  replacementExpected = oracle.transition {
    sourceState = cloneState;
    inherit targetState policy;
    previousPhysical = cloneExpected.physical.nodes;
  };
  sourceIds = builtins.attrNames sourceState;
  consumerBundle = fixture.consumerPackages "runner-operation" ([ "host" ] ++ sourceIds);
  degradedSubstituterShim = { lib, ... }:
    let
      outerPath = builtins.head (lib.splitString " "
        v1Base.config.systemd.services.nixtache-overlay-prepare.script);
      outerText = builtins.readFile outerPath;
      innerPath = builtins.head (lib.splitString "\n"
        (builtins.elemAt (lib.splitString "unshare -m --propagation private " outerText) 1));
      innerText = builtins.readFile innerPath;
      dropFunction = ''
        drop_target_dependencies() {
          [ -r /run/nixtache-overlay-test-substituter ] || return 0
          while read -r dependency; do
            [ -n "$dependency" ] || continue
            find "$stage" -path "*/upper/$(basename "$dependency")" -type f -delete
          done < /run/nixtache-overlay-test-substituter
          echo "nixtache-overlay-test: removed target-only dependencies for substituter check" >&2
        }
      '';
      injectedInner = pkgs.writeShellScript "nixtache-overlay-verify-degraded-substituter"
        (builtins.replaceStrings [
          "set -euo pipefail\n"
          "lower_url=$(uri_encode \"local?root=$lower_root&state=$stage/host/lower-state&read-only=true\")\n"
        ] [
          "set -euo pipefail\n${dropFunction}"
          "lower_url=$(uri_encode \"local?root=$lower_root&state=$stage/host/lower-state&read-only=true\")\ndrop_target_dependencies\n"
        ] innerText);
      injectedOuter = pkgs.writeShellScript "nixtache-overlay-prepare-degraded-substituter"
        (builtins.replaceStrings
          [ "unshare -m --propagation private ${innerPath}" ]
          [ "unshare -m --propagation private ${injectedInner}" ]
          outerText);
    in
    {
      systemd.services.nixtache-overlay-prepare.script = lib.mkForce "${injectedOuter} --installed";
    };
  v1Base = fixture.mkAppliance {
    version = "1";
    state = sourceState;
    inherit policy;
    lowerDependencies = builtins.attrValues consumerBundle.dependencies;
  };
  v1 = if policy == "reconcile" then v1Base.extendModules {
    modules = [ degradedSubstituterShim ];
  } else v1Base;
  v2 = fixture.mkAppliance {
    version = "2";
    state = cloneState;
    inherit policy;
    brokenBoot = true;
  };
  v3 = fixture.mkAppliance {
    version = "3";
    state = targetState;
    inherit policy;
    brokenBoot = true;
    bootTries = 1;
  };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2Package = v2.config.system.build.sysupdate-package;
  v3Package = v3.config.system.build.sysupdate-package;
in
assert lib.assertMsg (builtins.elem policy [ "reconcile" "wipe" ])
  "runner topology operation policy must be reconcile or wipe";
pkgs.testers.runNixOSTest {
  name = "runner-topology-operations-${policy}";
  globalTimeout = 10800;

  nodes.deployer = fixture.deployerNode ([ v2Package v3Package ] ++ consumerBundle.allPackages);

  testScript = ''
    import json
    import shlex
    from typing import TypedDict

    class RunnerSettings(TypedDict):
        parent: str | None
        mode: str
        path: str
        hostBackup: str
        containerName: str
        lowerRoot: str
        socket: str

    class ExpectedPhysicalNode(TypedDict):
        id: str
        logicalId: str
        role: str
        parent: str | None

    class ExpectedPhysicalGraph(TypedDict):
        nodes: list[ExpectedPhysicalNode]
        order: list[str]

    class ExpectedGraph(TypedDict):
        nodes: list[dict[str, object]]
        order: list[str]
        physical: ExpectedPhysicalGraph
        consumerNodeByLogical: dict[str, str]
        frozenLowerByLogical: dict[str, str]
        lineageByPhysical: dict[str, dict[str, object]]
        generationFingerprint: str
        operations: dict[str, str]
        dispositions: dict[str, str]

    POLICY = ${builtins.toJSON policy}
    SOURCE_RUNNERS: dict[str, RunnerSettings] = json.loads(${builtins.toJSON (builtins.toJSON (fixture.pythonRunners sourceState))})
    CLONE_RUNNERS: dict[str, RunnerSettings] = json.loads(${builtins.toJSON (builtins.toJSON (fixture.pythonContainers cloneState))})
    TARGET_RUNNERS: dict[str, RunnerSettings] = json.loads(${builtins.toJSON (builtins.toJSON (fixture.pythonRunners targetState))})
    RUNNERS = SOURCE_RUNNERS
    SOURCE_GRAPH: ExpectedGraph = json.loads(${builtins.toJSON (builtins.toJSON (oracle.projection sourceExpected))})
    CLONE_GRAPH: ExpectedGraph = json.loads(${builtins.toJSON (builtins.toJSON (oracle.projection cloneExpected))})
    TARGET_GRAPH: ExpectedGraph = json.loads(${builtins.toJSON (builtins.toJSON (oracle.projection replacementExpected))})
    EXPECTED_GRAPH = SOURCE_GRAPH
    CONSUMERS = ${builtins.toJSON consumerBundle.consumerPaths}
    DEPENDENCIES = ${builtins.toJSON consumerBundle.dependencyPaths}
    SYSUPDATE_PACKAGES = {"2": ${builtins.toJSON v2Package.outPath}, "3": ${builtins.toJSON v3Package.outPath}}

    ${fixture.pythonHelpers}

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; memory = "4096"; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def assert_source_working():
        appliance.succeed("test -f " + q(CONSUMERS["host"]) + " && test -f " + q(DEPENDENCIES["host"]))
        appliance.succeed("grep -Fqx " + q(DEPENDENCIES["host"]) + " " + q(CONSUMERS["host"]))
        for node in RUNNERS:
            assert_merged(node, CONSUMERS[node])
            assert_merged(node, DEPENDENCIES[node])
            crun(node, "grep -Fqx " + q(DEPENDENCIES[node]) + " " + q(merged_path(node, CONSUMERS[node])))
            path_info(node, CONSUMERS[node])
            path_info(node, DEPENDENCIES[node])

    def assert_preparation_blocked(slot, active, active_checksum):
        root = "/var/lib/nix-overlay/upper-slots/" + slot
        appliance.fail("test -e " + q(root + "/current") + " || test -L " + q(root + "/current"))
        appliance.fail("grep -l '^state=ready$' " + q(root) + "/generations/*/metadata 2>/dev/null")
        assert selected_generation() == active
        assert tree_checksum(active) == active_checksum, "failed preparation modified the active graph"
        assert_source_working()

    def ancestors(node):
        result = []
        parent = RUNNERS[node]["parent"]
        while parent is not None:
            result.append(parent)
            parent = RUNNERS[parent]["parent"]
        return result + ["host"]

    def assert_unblessed(counted=True):
        appliance.wait_until_succeeds(
          "systemctl is-failed --quiet nixtache-runner-topology-canary.service", timeout=120
        )
        if counted:
            appliance.wait_until_succeeds(
              "systemctl is-failed --quiet nixtache-health-check.service", timeout=120
            )
        appliance.fail("systemctl is-active --quiet boot-complete.target")

    def assert_operation_runtime():
        if POLICY == "reconcile":
            for node in RUNNERS:
                if RUNNERS[node]["mode"] == "clone":
                    continue
                visible = set(ancestors(node))
                if node not in ("reset", "addSibling", "addDeep", "stable"):
                    visible.add(node)
                for owner, path in CONSUMERS.items():
                    if owner in visible:
                        path_info(node, path)
                        assert_merged(node, path)
                        assert_merged(node, DEPENDENCIES[owner])
                    else:
                        path_absent(node, path)
                for owner in visible - {node}:
                    assert_runtime_upper(node, CONSUMERS[owner], expected=False)
            print("OK: target runtime resolves retained consumers through the new parent lineage with no sibling leakage")
        else:
            for node in RUNNERS:
                if RUNNERS[node]["mode"] == "clone":
                    continue
                for path in CONSUMERS.values():
                    path_absent(node, path)
                    assert_merged(node, path, expected=False)
            print("OK: wiped target runtime contains no source consumer or upper-owned record")

    def seed_clone_store():
        realize("stable", CONSUMERS["stable"])
        assert_merged("stable", CONSUMERS["stable"])
        assert_merged("stable", DEPENDENCIES["stable"])
        path_info("stable", CONSUMERS["stable"])
        path_info("stable", DEPENDENCIES["stable"])
        assert_clone_store("stable", CONSUMERS["stable"])
        assert_clone_store("stable", DEPENDENCIES["stable"])

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    wait_graph()

    realize_host(CONSUMERS["host"])
    for node in RUNNERS:
        realize(node, CONSUMERS[node])
    assert_source_working()
    v1_selected = selected_generation()
    v1_checksum = tree_checksum(v1_selected)
    print("OK: source consumers reference dependencies present only in the v1 lower")

    v2_slot = stage("2")
    if POLICY == "reconcile":
        appliance.succeed("printf '%s\\n' " + q(DEPENDENCIES["host"]) + " > /run/nixtache-overlay-test-substituter")
        deployer.succeed("systemctl stop nix-serve.service")
        appliance.fail("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert_preparation_blocked(v2_slot, v1_selected, v1_checksum)
        deployer.succeed("systemctl start nix-serve.service")
        deployer.wait_for_unit("nix-serve.service")
        print("OK: unavailable repair substituter left the operation target unready and active state intact")
    else:
        descriptor = "/boot/EFI/nixtache/abtest_2.overlay-topology.json"
        appliance.succeed("cp " + q(descriptor) + " /tmp/runner-operation-descriptor.json && rm " + q(descriptor))
        appliance.fail("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert_preparation_blocked(v2_slot, v1_selected, v1_checksum)
        appliance.succeed("cp /tmp/runner-operation-descriptor.json " + q(descriptor))
        print("OK: interrupted descriptor availability blocked publication and preserved active state")

    EXPECTED_GRAPH = CLONE_GRAPH
    v2_target = prepare("2", v2_slot)
    assert selected_generation() == v1_selected
    assert tree_checksum(v1_selected) == v1_checksum, "successful retry changed the active source graph"
    assert_source_working()
    plan = assert_plan(v2_target)
    assert plan["operations"]["addSibling"] == "add"
    assert plan["operations"]["addDeep"] == "add"
    assert plan["operations"]["move"] == "reparent"
    assert plan["operations"]["moveLeaf"] == "promote"
    assert plan["operations"]["reset"] == "storage-reset"
    assert plan["operations"]["removeChild"] == "remove"
    assert plan["operations"]["removeRoot"] == "remove"
    assert plan["operations"]["stable"] == "remove"
    print("OK: retry published the exact add/reparent/remove/storage/mode operation oracle")

    if POLICY == "reconcile":
        for logical_id in ("host", "a", "b", "move", "moveLeaf"):
            frozen_id = EXPECTED_GRAPH["frozenLowerByLogical"][logical_id]
            assert_consumer(v2_target + "/nodes/" + frozen_id, logical_id, CONSUMERS[logical_id])
        for logical_id in ("reset", "addSibling", "addDeep"):
            assert_empty_node(consumer_dir(v2_target, logical_id))
            if logical_id == "reset":
                assert_consumer_absent(consumer_dir(v2_target, logical_id), logical_id, CONSUMERS[logical_id])
        for logical_id in ("a", "b", "move", "moveLeaf"):
            frozen_dir = v2_target + "/nodes/" + EXPECTED_GRAPH["frozenLowerByLogical"][logical_id]
            appliance.succeed("test -f " + q(upper_marker(frozen_dir, DEPENDENCIES[logical_id])))
            assert_db_record(frozen_dir, DEPENDENCIES[logical_id])
        appliance.fail(
          "test -e " + q(upper_marker(v2_target + "/nodes/a-lower", CONSUMERS["move"])) +
          " || test -L " + q(upper_marker(v2_target + "/nodes/a-lower", CONSUMERS["move"]))
        )
        print("OK: unchanged and moved state survived, reset/new state is empty, and moved dependencies revalidated")
    else:
        for physical_node in EXPECTED_GRAPH["physical"]["nodes"]:
            assert_empty_node(node_dir(v2_target, physical_node["id"]))
        print("OK: wipe produced the same physical graph with completely clean target state")

    for physical_id in ("stable", "stable-lower", "stable-runtime"):
        appliance.fail("test -e " + q(v2_target + "/nodes/" + physical_id) + " || test -L " + q(v2_target + "/nodes/" + physical_id))
    appliance.fail("test -e " + q(v2_target + "/layers/stable") + " || test -L " + q(v2_target + "/layers/stable"))
    for logical_id in ("removeRoot", "removeChild"):
        appliance.fail("test -e " + q(v2_target + "/layers/" + logical_id) + " || test -L " + q(v2_target + "/layers/" + logical_id))
    for physical_id in ("removeRoot", "removeRoot-lower", "removeRoot-runtime", "removeChild"):
        appliance.fail("test -e " + q(v2_target + "/nodes/" + physical_id) + " || test -L " + q(v2_target + "/nodes/" + physical_id))

    RUNNERS = CLONE_RUNNERS
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph(blessed=False)
    assert selected_generation() == v2_target
    assert_unblessed()

    assert_operation_runtime()
    seed_clone_store()

    v2_proof = build_proof("addDeep", "v2-only-" + POLICY)
    assert crun("addDeep", "cat " + q(merged_path("addDeep", v2_proof))).strip() == "v2-only-" + POLICY
    clone_proof = build_proof("stable", "stable-clone-" + POLICY)
    assert crun("stable", "cat " + q(merged_path("stable", clone_proof))).strip() == "stable-clone-" + POLICY
    assert_clone_store("stable", clone_proof)
    print("OK: clone mode has no stable metaslot and writes to its independent additive store")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph(blessed=False)
    path_info("addDeep", v2_proof)
    path_info("stable", clone_proof)
    assert_clone_store("stable", CONSUMERS["stable"])
    assert_clone_store("stable", clone_proof)
    assert_unblessed()
    print("OK: v2 graph and both overlay/clone writes persisted across its second unblessed boot")

    # The v3 installation reuses the v1 physical slot. Verify rollback while
    # that lower is intact, then force v2 for the clone-to-overlay transition.
    RUNNERS = SOURCE_RUNNERS
    EXPECTED_GRAPH = SOURCE_GRAPH
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    wait_graph(already_blessed=True)
    assert selected_generation() == v1_selected
    assert tree_checksum(v1_selected) == v1_checksum, "rollback changed the preserved source generation"
    assert_source_working()
    for node in RUNNERS:
        path_absent(node, v2_proof)
        path_absent(node, clone_proof)
    assert_clone_store("stable", CONSUMERS["stable"])
    assert_clone_store("stable", clone_proof)
    appliance.succeed(
      "test -f " + q(v2_target + "/nodes/addDeep/upper/" + basename(v2_proof))
    )
    log = appliance.succeed(
      "journalctl -b -u nixtache-overlay-select.service -u nixtache-overlay-prepare.service --no-pager -o cat"
    )
    for marker in ("nixtache-overlay: repairing ", "nixtache-overlay: prepared ", "nixtache-overlay: checking "):
        assert marker not in log, f"rollback ran reverse preparation: {log}"
    print("OK: rollback restored the exact previous graph without reverse preparation")

    RUNNERS = CLONE_RUNNERS
    EXPECTED_GRAPH = CLONE_GRAPH
    # Exhausted counted entries are not selectable with set-oneshot, so reuse
    # the v2 UKI as the plain fallback entry for this forced continuation boot.
    appliance.succeed(
      "cp /boot/EFI/Linux/abtest_2+*.efi /boot/EFI/Linux/abtest_1.efi && "
      "bootctl set-default abtest_1.efi"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph(blessed=False)
    assert selected_generation() == v2_target
    # Plain fallback entries do not pull in the counted health check; the
    # failed canary and inactive target still prove this continuation is unblessed.
    assert_unblessed(counted=False)
    path_info("addDeep", v2_proof)
    path_info("stable", clone_proof)
    assert_clone_store("stable", clone_proof)

    v2_checksum = tree_checksum(v2_target)
    v3_slot = stage("3")
    EXPECTED_GRAPH = TARGET_GRAPH
    v3_target = prepare("3", v3_slot)
    assert selected_generation() == v2_target
    assert tree_checksum(v2_target) == v2_checksum, "replacement preparation changed the active clone graph"
    plan = assert_plan(v3_target)
    assert plan["operations"]["stable"] == "add"
    stable_dir = consumer_dir(v3_target, "stable")
    assert_empty_node(stable_dir)
    assert_consumer_absent(stable_dir, "stable", CONSUMERS["stable"])
    assert_clone_store("stable", CONSUMERS["stable"])
    assert_clone_store("stable", DEPENDENCIES["stable"])
    assert_clone_store("stable", clone_proof)
    print("OK: clone-to-overlay published an empty replacement node and preserved the additive clone store")

    RUNNERS = TARGET_RUNNERS
    # Leave the forced v2 fallback behind and select the fresh counted v3 entry.
    appliance.succeed("bootctl set-default \"$(basename /boot/EFI/Linux/abtest_3+*.efi)\"")
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "3"
    wait_graph(blessed=False)
    assert selected_generation() == v3_target
    assert_unblessed()
    assert_operation_runtime()
    path_absent("stable", CONSUMERS["stable"])
    path_absent("stable", clone_proof)
    assert_runtime_upper("stable", CONSUMERS["stable"], expected=False)
    assert_runtime_upper("stable", clone_proof, expected=False)
    assert_clone_store("stable", CONSUMERS["stable"])
    assert_clone_store("stable", clone_proof)
    print("OK: replacement overlay is clean at runtime while the additive clone remains intact")

    print("PASS: ${policy} operation and clone-mode OTA converged after retry; rollback restored the exact previous graph")
  '';
}

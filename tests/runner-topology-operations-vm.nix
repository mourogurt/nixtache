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
  targetState = lib.foldl' oracle.applyOperation sourceState operations;
  sourceDirect = oracle.derive { state = sourceState; };
  sourceExpected = oracle.transition {
    inherit sourceState;
    targetState = sourceState;
    previousPhysical = sourceDirect.physical.nodes;
    inherit policy;
  };
  expected = oracle.transition {
    inherit sourceState targetState policy;
    previousPhysical = sourceDirect.physical.nodes;
  };
  sourceIds = builtins.attrNames sourceState;
  consumerBundle = fixture.consumerPackages "runner-operation" ([ "host" ] ++ sourceIds);
  v1 = fixture.mkAppliance {
    version = "1";
    state = sourceState;
    inherit policy;
    lowerDependencies = builtins.attrValues consumerBundle.dependencies;
  };
  v2 = fixture.mkAppliance {
    version = "2";
    state = targetState;
    inherit policy;
    brokenBoot = true;
  };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2Package = v2.config.system.build.sysupdate-package;
in
assert lib.assertMsg (builtins.elem policy [ "reconcile" "wipe" ])
  "runner topology operation policy must be reconcile or wipe";
pkgs.testers.runNixOSTest {
  name = "runner-topology-operations-${policy}";
  globalTimeout = 10800;

  nodes.deployer = fixture.deployerNode ([ v2Package ] ++ consumerBundle.allPackages);

  testScript = ''
    import json
    import shlex

    POLICY = ${builtins.toJSON policy}
    SOURCE_RUNNERS = ${builtins.toJSON (fixture.pythonRunners sourceState)}
    TARGET_RUNNERS = ${builtins.toJSON (fixture.pythonRunners targetState)}
    RUNNERS = SOURCE_RUNNERS
    SOURCE_GRAPH = ${builtins.toJSON (oracle.projection sourceExpected)}
    TARGET_GRAPH = ${builtins.toJSON (oracle.projection expected)}
    EXPECTED_GRAPH = SOURCE_GRAPH
    CONSUMERS = ${builtins.toJSON consumerBundle.consumerPaths}
    DEPENDENCIES = ${builtins.toJSON consumerBundle.dependencyPaths}
    SYSUPDATE_PACKAGES = {"2": ${builtins.toJSON v2Package.outPath}}

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

    def assert_unblessed():
        appliance.wait_until_succeeds(
          "systemctl is-failed --quiet nixtache-runner-topology-canary.service", timeout=120
        )
        appliance.wait_until_succeeds(
          "systemctl is-failed --quiet nixtache-health-check.service", timeout=120
        )
        appliance.fail("systemctl is-active --quiet boot-complete.target")

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

    EXPECTED_GRAPH = TARGET_GRAPH
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
    assert plan["operations"]["stable"] == "unchanged"
    print("OK: retry published the exact add/reparent/remove/storage operation oracle")

    if POLICY == "reconcile":
        for logical_id in ("host", "a", "b", "move", "moveLeaf"):
            frozen_id = EXPECTED_GRAPH["frozenLowerByLogical"][logical_id]
            assert_consumer(v2_target + "/nodes/" + frozen_id, logical_id, CONSUMERS[logical_id])
        stable_dir = consumer_dir(v2_target, "stable")
        assert_consumer(stable_dir, "stable", CONSUMERS["stable"])
        appliance.succeed("test -f " + q(upper_marker(stable_dir, DEPENDENCIES["stable"])))
        assert_db_record(stable_dir, DEPENDENCIES["stable"])
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

    for logical_id in ("removeRoot", "removeChild"):
        appliance.fail("test -e " + q(v2_target + "/layers/" + logical_id) + " || test -L " + q(v2_target + "/layers/" + logical_id))
    for physical_id in ("removeRoot", "removeRoot-lower", "removeRoot-runtime", "removeChild"):
        appliance.fail("test -e " + q(v2_target + "/nodes/" + physical_id) + " || test -L " + q(v2_target + "/nodes/" + physical_id))

    RUNNERS = TARGET_RUNNERS
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph(blessed=False)
    assert selected_generation() == v2_target
    assert_unblessed()

    if POLICY == "reconcile":
        for node in RUNNERS:
            visible = set(ancestors(node))
            if node not in ("reset", "addSibling", "addDeep"):
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
            for path in CONSUMERS.values():
                path_absent(node, path)
                assert_merged(node, path, expected=False)
        print("OK: wiped target runtime contains no source consumer or upper-owned record")

    v2_proof = build_proof("addDeep", "v2-only-" + POLICY)
    assert crun("addDeep", "cat " + q(merged_path("addDeep", v2_proof))).strip() == "v2-only-" + POLICY

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph(blessed=False)
    path_info("addDeep", v2_proof)
    assert_unblessed()
    print("OK: v2 graph and v2-only write persisted across its second unblessed boot")

    RUNNERS = SOURCE_RUNNERS
    EXPECTED_GRAPH = SOURCE_GRAPH
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    wait_graph()
    assert selected_generation() == v1_selected
    assert tree_checksum(v1_selected) == v1_checksum, "rollback changed the preserved source generation"
    assert_source_working()
    for node in RUNNERS:
        path_absent(node, v2_proof)
    appliance.succeed(
      "test -f " + q(v2_target + "/nodes/addDeep/upper/" + basename(v2_proof))
    )
    log = appliance.succeed(
      "journalctl -b -u nixtache-overlay-select.service -u nixtache-overlay-prepare.service --no-pager -o cat"
    )
    for marker in ("nixtache-overlay: repairing ", "nixtache-overlay: prepared ", "nixtache-overlay: checking "):
        assert marker not in log, f"rollback ran reverse preparation: {log}"
    print("PASS: ${policy} operation OTA converged after retry and rollback restored the exact previous graph")
  '';
}

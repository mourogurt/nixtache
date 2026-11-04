{ nixpkgs
, self
, system ? "x86_64-linux"
, topology ? "sibling"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  fixture = import ./runner-topology-vm-lib.nix {
    inherit nixpkgs self system appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib oracle;
  state = if topology == "nested" then {
    middle = oracle.node "middle" { };
    leaf = oracle.node "leaf" { parent = "middle"; };
  } else if topology == "composed" then {
    a = oracle.node "a" { };
    b = oracle.node "b" { };
    grand = oracle.node "grand" { parent = "a"; };
  } else {
    left = oracle.node "left" { };
    right = oracle.node "right" { };
  };
  runnerIds = builtins.attrNames state;
  direct = oracle.derive { inherit state; };
  expected = oracle.transition {
    sourceState = state;
    targetState = state;
    previousPhysical = direct.physical.nodes;
    policy = "reconcile";
  };
  markers = fixture.markerPackages "runner-topology-${topology}" ([ "host" ] ++ runnerIds);
  markerPaths = fixture.packagePaths markers;
  v1 = fixture.mkAppliance { version = "1"; inherit state; };
  v2 = fixture.mkAppliance { version = "2"; inherit state; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2Package = v2.config.system.build.sysupdate-package;
in
assert lib.assertMsg (builtins.elem topology [ "sibling" "nested" "composed" ])
  "runner topology must be sibling, nested or composed";
pkgs.testers.runNixOSTest {
  name = "runner-topology-${topology}";
  globalTimeout = 7200;

  nodes.deployer = fixture.deployerNode ([ v2Package ] ++ builtins.attrValues markers);

  testScript = ''
    import json
    import shlex

    POLICY = "reconcile"
    RUNNERS = ${builtins.toJSON (fixture.pythonRunners state)}
    MARKERS = ${builtins.toJSON markerPaths}
    EXPECTED_GRAPH = ${builtins.toJSON (oracle.projection expected)}
    SYSUPDATE_PACKAGES = {"2": ${builtins.toJSON v2Package.outPath}}

    ${fixture.pythonHelpers}

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; memory = "4096"; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def ancestors(node):
        result = []
        parent = RUNNERS[node]["parent"]
        while parent is not None:
            result.append(parent)
            parent = RUNNERS[parent]["parent"]
        return result + ["host"]

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

    realize_host(MARKERS["host"])
    for node in RUNNERS:
        realize(node, MARKERS[node])
    for node in RUNNERS:
        path_info(node, MARKERS[node])
        assert_runtime_upper(node, MARKERS[node])
        for owner, path in MARKERS.items():
            if owner != node:
                path_absent(node, path)
    print("OK: runtime parent writes and every sibling write remain isolated before rebase")

    v1_selected = selected_generation()
    v1_checksum = tree_checksum(v1_selected)
    v2_slot = stage("2")
    v2_target = prepare("2", v2_slot)
    assert selected_generation() == v1_selected
    assert tree_checksum(v1_selected) == v1_checksum, "target preparation changed the active source generation"

    for logical_id, frozen_id in EXPECTED_GRAPH["frozenLowerByLogical"].items():
        assert_consumer(v2_target + "/nodes/" + frozen_id, logical_id, MARKERS[logical_id])
    for node in RUNNERS:
        if node not in EXPECTED_GRAPH["frozenLowerByLogical"]:
            assert_consumer(consumer_dir(v2_target, node), node, MARKERS[node])
    print("OK: prepared frozen lowers contain parent files, roots and validity records before cutover")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_graph()
    assert selected_generation() == v2_target

    for node in RUNNERS:
        visible = set(ancestors(node) + [node])
        for owner, path in MARKERS.items():
            if owner in visible:
                path_info(node, path)
            else:
                path_absent(node, path)
        for owner in visible - {node}:
            path = MARKERS[owner]
            assert_runtime_upper(node, path, expected=False)
            appliance.succeed(
              "test -f " + q(RUNNERS[node]["lowerRoot"] + "/nix/store/" + basename(path))
            )
        if node in EXPECTED_GRAPH["frozenLowerByLogical"]:
            assert_runtime_upper(node, MARKERS[node], expected=False)
            appliance.succeed(
              "test -f " + q(v2_target + "/nodes/" + node + "-lower/upper/" + basename(MARKERS[node]))
            )
        else:
            assert_runtime_upper(node, MARKERS[node])
    print("OK: after restart each nested lower resolves exactly its own and ancestor frozen state")

    proofs = {}
    for node in RUNNERS:
        proofs[node] = build_proof(node, "${topology}-post-rebase-" + node)
        assert crun(node, "cat " + q(merged_path(node, proofs[node]))).strip() == "${topology}-post-rebase-" + node
        for other in RUNNERS:
            if other != node:
                path_absent(other, proofs[node])
    print("PASS: production ${topology} runner declarations preserve parent roots, isolation, nested resolution and readiness")
  '';
}

{ nixpkgs
, self
, system ? "x86_64-linux"
, ephemeralNode ? "host"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  topology = "composed";
  upperOnUpdate = "reconcile";
  fixture = import ./overlay-tree-vm-lib.nix {
    inherit nixpkgs self system topology upperOnUpdate ephemeralNode appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib;

  v1 = fixture.mkAppliance { version = "1"; withDependencies = true; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  cacheDependencies = builtins.filter
    (package: package.outPath != fixture.v2SysupdatePkg.outPath)
    fixture.deployerDependencies;
  markerPackages = lib.genAttrs fixture.nodeIds (node: pkgs.runCommand
    "overlay-tree-ephemeral-${ephemeralNode}-${node}" { } ''
      printf '%s\n' '${ephemeralNode}:${node}' > $out
    '');
  markerPaths = lib.mapAttrs (_: package: package.outPath) markerPackages;
in
assert lib.assertMsg (builtins.elem ephemeralNode [ "host" "a" ])
  "overlay-tree ephemeral suite requires host or a";
pkgs.testers.runNixOSTest {
  name = "overlay-tree-ephemeral-${ephemeralNode}";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = cacheDependencies ++ builtins.attrValues markerPackages;
  };

  testScript = ''
    import shlex

    EPHEMERAL = ${builtins.toJSON ephemeralNode}
    NODE_IDS = ${builtins.toJSON fixture.nodeIds}
    ROOTS = ${builtins.toJSON fixture.roots}
    UPPERS = ${builtins.toJSON fixture.upperDirs}
    WORKS = ${builtins.toJSON fixture.workDirs}
    STATES = ${builtins.toJSON fixture.stateDirs}
    STORES = ${builtins.toJSON fixture.storeUrls}
    MOUNT_UNITS = ${builtins.toJSON fixture.mountUnitNames}
    CONSUMERS = ${builtins.toJSON fixture.consumersByNode}
    EXTRA_ROOTS = ${builtins.toJSON fixture.extraRoots}
    MARKERS = ${builtins.toJSON markerPaths}
    PATHS = ${builtins.toJSON fixture.fixturePaths}
    RESET_NODES = NODE_IDS if EPHEMERAL == "host" else ["a", "grand"]

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def q(value):
        return shlex.quote(value)

    def basename(path):
        return path.rsplit("/", 1)[-1]

    def fs_path(node, store_path):
        return ROOTS[node].rstrip("/") + store_path

    def nix_store(node, args):
        features = "ca-derivations local-overlay-store read-only-local-store"
        return "nix-store --option experimental-features " + q(features) + " --store " + q(STORES[node]) + " " + args

    def nix_cli(node, args):
        features = "nix-command ca-derivations local-overlay-store read-only-local-store"
        return "nix --extra-experimental-features " + q(features) + " --store " + q(STORES[node]) + " " + args

    def realize(node, path):
        appliance.succeed(nix_store(node, "--realize " + q(path)), timeout=600)

    def add_root(node, path, name):
        root = STATES[node] + "/gcroots/" + name
        appliance.succeed("mkdir -p " + q(STATES[node] + "/gcroots") + " && ln -sfn " + q(path) + " " + q(root))

    def seed_root(node, path):
        realize(node, path)
        add_root(node, path, "overlay-tree-" + node)

    def state_path(node):
        return STATES[node]

    def db_hashes(nodes):
        return {
          node: appliance.succeed(
            "sha256sum " + q(state_path(node) + "/db/db.sqlite") + " | awk '{print $1}'"
          ).strip()
          for node in nodes
        }

    def assert_runtime_consumers(nodes):
        for node, consumer in CONSUMERS.items():
            if node not in nodes:
                continue
            requisites = nix_store(node, "-q --requisites " + q(consumer))
            root = ROOTS[node].rstrip("/")
            appliance.succeed(
              "for path in $(" + requisites + "); do "
              "test -e " + q(root) + "$path || { echo \"missing closure path $path\" >&2; exit 1; }; done",
              timeout=300,
            )

    def assert_whole_tree():
        for node in NODE_IDS:
            listing = "/tmp/overlay-tree-ephemeral-" + node + "-valid-paths"
            appliance.succeed(nix_cli(node, "path-info --all") + " > " + q(listing), timeout=600)
            root = ROOTS[node].rstrip("/")
            appliance.succeed(
              "while IFS= read -r path; do "
              "test -e " + q(root) + "$path || { echo \"missing whole-tree path at " + node + ": $path\" >&2; exit 1; }; "
              "done < " + q(listing),
              timeout=600,
            )
            appliance.succeed(nix_cli(node, "path-info " + q(PATHS["hostDependency"])))

    def wait_ready_tree():
        try:
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet nixtache-overlay-ready.target", timeout=300
            )
        except Exception:
            print(appliance.succeed("systemctl status boot-complete.target nixtache-health-check.service --no-pager -l 2>&1 || true"))
            print(appliance.succeed("systemctl list-jobs --no-legend 2>&1 || true"))
            raise
        appliance.wait_until_succeeds("nix --version", timeout=300)
        for unit in MOUNT_UNITS:
            appliance.wait_until_succeeds("systemctl is-active --quiet " + unit, timeout=180)

    def sentinel_dirs(node):
        return [
          UPPERS[node],
          WORKS[node],
          STATES[node] + "/db",
          STATES[node] + "/gcroots",
          STATES[node] + "/profiles",
          STATES[node] + "/temproots",
        ]

    def plant_sentinels():
        for node in NODE_IDS:
            for directory in sentinel_dirs(node):
                appliance.succeed("mkdir -p " + q(directory) + " && touch " + q(directory + "/ephemeral-sentinel"))

    def assert_sentinels():
        for node in NODE_IDS:
            for directory in sentinel_dirs(node):
                if node in RESET_NODES:
                    appliance.fail("test -e " + q(directory + "/ephemeral-sentinel"))
                else:
                    appliance.succeed("test -e " + q(directory + "/ephemeral-sentinel"))

    def assert_markers_valid(nodes):
        for node in nodes:
            path = MARKERS[node]
            appliance.succeed(nix_cli(node, "path-info " + q(path)))
            root = STATES[node] + "/gcroots/ephemeral-marker"
            assert appliance.succeed("readlink " + q(root)).strip() == path
            appliance.succeed("grep -Fqx " + q(EPHEMERAL + ":" + node) + " " + q(fs_path(node, path)))

    def assert_markers_invalid(nodes):
        for node in nodes:
            path = MARKERS[node]
            appliance.fail(nix_cli(node, "path-info " + q(path)))
            root = STATES[node] + "/gcroots/ephemeral-marker"
            appliance.fail("test -e " + q(root) + " || test -L " + q(root))

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    wait_ready_tree()

    for node in NODE_IDS:
        seed_root(node, CONSUMERS[node])
    for root in EXTRA_ROOTS:
        realize(root["node"], root["path"])
        add_root(root["node"], root["path"], root["name"])
    for node in reversed(NODE_IDS):
        realize(node, MARKERS[node])
        add_root(node, MARKERS[node], "ephemeral-marker")
    assert_markers_valid(NODE_IDS)
    assert_runtime_consumers(NODE_IDS)
    print("OK: composed consumers and unique registered markers work at every node before reboot")

    persistent_nodes = [node for node in NODE_IDS if node not in RESET_NODES]
    persistent_hashes = db_hashes(persistent_nodes)
    persistent_generation = None
    if persistent_nodes:
        persistent_generation = appliance.succeed(
          "readlink -f /var/lib/nix-overlay/upper-slots/$(cat /run/nixtache-overlay/selected-slot)/current"
        ).strip()

    for unit in MOUNT_UNITS + ["nix-daemon-overlay-mount.service", "nix-daemon.service", "nix-daemon.socket"]:
        appliance.succeed("systemctl stop " + unit + " || true")
    plant_sentinels()
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    wait_ready_tree()
    assert_sentinels()
    assert_markers_invalid(RESET_NODES)
    assert_markers_valid(persistent_nodes)
    assert_runtime_consumers(persistent_nodes)

    if persistent_nodes:
        assert db_hashes(persistent_nodes) == persistent_hashes, "persistent DBs changed during descendant reset"
        assert appliance.succeed(
          "readlink -f /var/lib/nix-overlay/upper-slots/$(cat /run/nixtache-overlay/selected-slot)/current"
        ).strip() == persistent_generation, "persistent generation changed during descendant reset"

    for node in RESET_NODES:
        realize(node, MARKERS[node])
        add_root(node, MARKERS[node], "ephemeral-marker")
    assert_markers_valid(RESET_NODES)
    assert_runtime_consumers(NODE_IDS)
    assert_whole_tree()
    print("PASS: ephemeral node=" + EPHEMERAL + " resets exactly its descendant subtree; persistent siblings remain coherent")
  '';
}

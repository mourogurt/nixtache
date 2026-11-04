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
    extraDependencies = cacheDependencies ++ builtins.attrValues markerPackages
      ++ lib.optional (ephemeralNode == "a") fixture.v2SysupdatePkg;
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

    def node_dir(target, node):
        return target + ("/host" if node == "host" else "/layers/" + node)

    def upper_path(node, path, target):
        return node_dir(target, node) + "/upper/" + basename(path)

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

    def prepare_installed_generation():
        active_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "cp ${fixture.v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
        )
        appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
        target_slot = appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=" + q(active_slot) + " "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()
        assert target_slot and target_slot != active_slot
        appliance.succeed("systemctl restart nixtache-overlay-prepare.service", timeout=900)
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == target_slot
        target_root = "/var/lib/nix-overlay/upper-slots/" + target_slot
        generation = appliance.succeed("readlink -f " + q(target_root + "/current")).strip()
        appliance.succeed("grep -q '^state=ready$' " + q(generation + "/metadata"))
        return generation

    def assert_no_host_metaslot():
        for base in ("/tmp/nix-overlay-host/upper-slots", "/tmp/nix-overlay-host/legacy-backup"):
            appliance.fail("find " + q(base) + " -mindepth 1 -print -quit 2>/dev/null | grep -q .")

    def assert_generation_layout(generation, persistent_nodes):
        for node in RESET_NODES:
            base = node_dir(generation, node)
            directories = [base + "/upper"] + [
              base + "/state/" + name for name in ("db", "gcroots", "profiles", "temproots")
            ]
            for directory in directories:
                appliance.fail("find " + q(directory) + " -mindepth 1 -print -quit 2>/dev/null | grep -q .")
        for node in persistent_nodes:
            path = MARKERS[node]
            marker = upper_path(node, path, generation)
            appliance.succeed("grep -Fqx " + q(EPHEMERAL + ":" + node) + " " + q(marker))
            root = node_dir(generation, node) + "/state/gcroots/ephemeral-marker"
            assert appliance.succeed("readlink " + q(root)).strip() == path
            db = node_dir(generation, node) + "/state/db/db.sqlite"
            sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
            assert appliance.succeed("sqlite3 " + q(db) + " " + q(sql)).strip() == "1"
        print("OK: prepared generation contains no persistent ephemeral upper or state copies; persistent siblings retain files, roots and DB records")

    def prepared_db_hashes(generation, nodes):
        return {
          node: appliance.succeed(
            "sha256sum " + q(node_dir(generation, node) + "/state/db/db.sqlite") + " | awk '{print $1}'"
          ).strip()
          for node in nodes
        }

    def active_db_hashes(nodes):
        return {
          node: appliance.succeed(
            "sha256sum " + q(STATES[node] + "/db/db.sqlite") + " | awk '{print $1}'"
          ).strip()
          for node in nodes
        }

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

    for unit in MOUNT_UNITS + ["nix-daemon-overlay-mount.service", "nix-daemon.service", "nix-daemon.socket"]:
        appliance.succeed("systemctl stop " + unit + " || true")
    plant_sentinels()
    if EPHEMERAL == "a":
        deployer.wait_for_unit("nginx.service")
        persistent_generation = prepare_installed_generation()
        assert_generation_layout(persistent_generation, persistent_nodes)
        prepared_hashes = prepared_db_hashes(persistent_generation, persistent_nodes)
    else:
        persistent_generation = None
        prepared_hashes = None
        assert_no_host_metaslot()
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert appliance.succeed("cat /etc/image-version").strip() == ("2" if EPHEMERAL == "a" else "1")
    wait_ready_tree()
    if EPHEMERAL == "a":
        assert_generation_layout(persistent_generation, persistent_nodes)
    else:
        assert_no_host_metaslot()
    assert_sentinels()
    assert_markers_invalid(RESET_NODES)
    assert_markers_valid(persistent_nodes)
    assert_runtime_consumers(persistent_nodes)

    if persistent_nodes:
        assert active_db_hashes(persistent_nodes) == prepared_hashes, "persistent sibling DBs changed while activating the ephemeral reset"
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

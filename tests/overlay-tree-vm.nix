{ nixpkgs
, self
, system ? "x86_64-linux"
, topology ? "sibling"
, upperOnUpdate ? "wipe"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  fixture = import ./overlay-tree-vm-lib.nix {
    inherit nixpkgs self system topology upperOnUpdate appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib;
in
pkgs.testers.runNixOSTest {
  name = "overlay-tree-${topology}-${upperOnUpdate}";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = fixture.deployerDependencies;
  };

  testScript = ''
    import re
    import shlex

    MODE = ${builtins.toJSON upperOnUpdate}
    TOPOLOGY = ${builtins.toJSON topology}
    NODE_IDS = ${builtins.toJSON fixture.nodeIds}
    ROOTS = ${builtins.toJSON fixture.roots}
    UPPERS = ${builtins.toJSON fixture.upperDirs}
    STATES = ${builtins.toJSON fixture.stateDirs}
    STORES = ${builtins.toJSON fixture.storeUrls}
    MOUNT_UNITS = ${builtins.toJSON fixture.mountUnitNames}
    CONSUMERS = ${builtins.toJSON fixture.consumersByNode}
    REPAIR_CASES = ${builtins.toJSON fixture.repairCases}
    EXTRA_ROOTS = ${builtins.toJSON fixture.extraRoots}
    PATHS = ${builtins.toJSON fixture.fixturePaths}

    if TOPOLOGY == "nested":
        NODE_DEPENDENCIES = {
          "host": PATHS["hostDependency"],
          "middle": PATHS["sharedDependency"],
          "leaf": PATHS["leafDependency"],
        }
    elif TOPOLOGY == "composed":
        NODE_DEPENDENCIES = {
          "host": PATHS["hostDependency"],
          "a": PATHS["sharedDependency"],
          "grand": PATHS["leafDependency"],
          "b": PATHS["commonDependency"],
        }
    else:
        NODE_DEPENDENCIES = {
          "host": PATHS["hostDependency"],
          "left": PATHS["commonDependency"],
          "right": PATHS["commonDependency"],
        }

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = fixture.v1Image; }}", **kwargs)
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

    def upper_path(node, path, target=None):
        upper = UPPERS[node] if target is None else node_dir(target, node) + "/upper"
        return upper + "/" + basename(path)

    def state_path(node, target=None):
        return STATES[node] if target is None else node_dir(target, node) + "/state"

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

    def active_state_checksum():
        archives = []
        for node in NODE_IDS:
            archives.append("tar --sort=name --numeric-owner -cf - -C " + q(UPPERS[node]) + " .")
            archives.append("tar --sort=name --numeric-owner -cf - -C " + q(STATES[node]) + " db gcroots profiles temproots")
        return appliance.succeed(
          "(" + "; ".join(archives) + ") 2>/dev/null | sha256sum | awk '{print $1}'"
        ).strip()

    def inactive_slot():
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=\"$(cat /run/nixtache-overlay/selected-slot)\" "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()

    def assert_placement(path, expected_nodes, target=None):
        for node in NODE_IDS:
            candidate = upper_path(node, path, target)
            if node in expected_nodes:
                appliance.succeed("test -e " + q(candidate))
            else:
                appliance.fail("test -e " + q(candidate))

    def assert_consumers(target=None):
        for node, path in CONSUMERS.items():
            assert_placement(path, [node], target)

    def assert_fixture_absent(target=None):
        for case in REPAIR_CASES:
            assert_placement(case["path"], [], target)
        for path in CONSUMERS.values():
            assert_placement(path, [], target)
        for node in NODE_IDS:
            root = state_path(node, target) + "/gcroots/overlay-tree-" + node
            appliance.fail("test -e " + q(root) + " || test -L " + q(root))
        for root in EXTRA_ROOTS:
            link = state_path(root["node"], target) + "/gcroots/" + root["name"]
            appliance.fail("test -e " + q(link) + " || test -L " + q(link))

    def assert_empty_tree(target):
        assert_fixture_absent(target)
        for node in NODE_IDS:
            upper = node_dir(target, node) + "/upper"
            state = node_dir(target, node) + "/state"
            appliance.fail("find " + q(upper) + " -mindepth 1 -print -quit | grep -q .")
            appliance.fail(
              "(find " + q(state + "/gcroots") + " " + q(state + "/profiles") +
              " -type l -print 2>/dev/null || true) | grep -q ."
            )
            db = state + "/db/db.sqlite"
            appliance.succeed(
              "if test -f " + q(db) + "; then "
              "test \"$(sqlite3 " + q(db) + " " + q("SELECT COUNT(*) FROM ValidPaths;") + ")\" = 0; fi"
            )

    def assert_db_record(target, node, path):
        db = node_dir(target, node) + "/state/db/db.sqlite"
        sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
        count = appliance.succeed("sqlite3 " + q(db) + " " + q(sql)).strip()
        assert count == "1", f"missing duplicated metadata for {path} in {node}: {count}"

    def assert_duplicated_metadata(target):
        if TOPOLOGY == "nested":
            assert_db_record(target, "leaf", PATHS["sharedConsumer"])
        elif TOPOLOGY == "composed":
            assert_db_record(target, "grand", PATHS["sharedConsumer"])
            for node in ("a", "b"):
                assert_db_record(target, node, PATHS["commonDependency"])
            assert_db_record(target, "b", PATHS["hostConsumer"])
        else:
            for node in ("left", "right"):
                assert_db_record(target, node, PATHS["hostConsumer"])
                assert_db_record(target, node, PATHS["commonDependency"])

    def assert_runtime_consumers():
        for node, consumer in CONSUMERS.items():
            requisites = nix_store(node, "-q --requisites " + q(consumer))
            root = ROOTS[node].rstrip("/")
            appliance.succeed(
              "for path in $(" + requisites + "); do "
              "test -e " + q(root) + "$path || { echo \"missing runtime closure path $path\" >&2; exit 1; }; done",
              timeout=300,
            )
            dependency = NODE_DEPENDENCIES[node]
            appliance.succeed("test -f " + q(fs_path(node, dependency)))
            appliance.succeed("grep -Fqx " + q(dependency) + " " + q(fs_path(node, consumer)))

    def assert_whole_tree():
        for node in NODE_IDS:
            listing = "/tmp/overlay-tree-" + node + "-valid-paths"
            appliance.succeed(nix_cli(node, "path-info --all") + " > " + q(listing), timeout=600)
            root = ROOTS[node].rstrip("/")
            appliance.succeed(
              "while IFS= read -r path; do "
              "test -e " + q(root) + "$path || { echo \"missing whole-tree path at " + node + ": $path\" >&2; exit 1; }; "
              "done < " + q(listing),
              timeout=600,
            )
            print("OK: final whole-tree closure verified at " + node)

    def cache_cursor():
        output = appliance.succeed(
          "journalctl -u nixtache-overlay-prepare.service -n 0 --show-cursor --no-pager"
        ).strip()
        return output.split("cursor:", 1)[1].strip()

    def cache_log(cursor):
        return appliance.succeed(
          "journalctl -u nixtache-overlay-prepare.service --after-cursor=" + q(cursor) + " --no-pager -o cat"
        )

    def narinfo_positions(log, path):
        return [match.start() for match in re.finditer(re.escape(path), log)]

    def assert_parent_first_fetches(cursor):
        log = cache_log(cursor)
        for parent, child in zip(NODE_IDS, NODE_IDS[1:]):
            repair_parent = narinfo_positions(log, "nixtache-overlay: repairing " + parent)
            prepared_parent = narinfo_positions(log, "nixtache-overlay: prepared " + parent)
            repair_child = narinfo_positions(log, "nixtache-overlay: repairing " + child)
            assert repair_parent and prepared_parent and repair_child, (
              f"missing preparation markers for {parent} or {child}"
            )
            assert max(repair_parent) < min(repair_child), (
              f"{parent} repair did not start before {child}"
            )
            assert max(prepared_parent) < min(repair_child), (
              f"{child} repair started before {parent} was prepared"
            )
        checked = [narinfo_positions(log, "nixtache-overlay: checking " + node) for node in NODE_IDS]
        assert all(checked), "missing final whole-tree validation markers"
        assert all(max(parent) < min(child) for parent, child in zip(checked, checked[1:])), (
          f"final validation is not parent-first: {checked}"
        )
        print("OK: preparation and final validation markers prove parent-before-child order")

    def wait_ready_tree():
        appliance.wait_until_succeeds(
          "systemctl is-active --quiet boot-complete.target", timeout=300
        )
        appliance.wait_until_succeeds("nix --version", timeout=300)
        for unit in MOUNT_UNITS:
            appliance.wait_until_succeeds("systemctl is-active --quiet " + unit, timeout=180)

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    wait_ready_tree()
    required = appliance.succeed(
      "systemctl show nixtache-overlay-ready.target -p Requires --value"
    ).split()
    for unit in MOUNT_UNITS:
        assert unit in required, f"{unit} is not required by nixtache-overlay-ready.target"
    print("OK: v1 real appliance booted with every runtime layer gated by overlay readiness")

    for node in NODE_IDS:
        seed_root(node, CONSUMERS[node])
    for root in EXTRA_ROOTS:
        realize(root["node"], root["path"])
        add_root(root["node"], root["path"], root["name"])
    for case in REPAIR_CASES:
        assert_placement(case["path"], [])
    assert_consumers()
    assert_runtime_consumers()
    print("OK: parent, intermediate, leaf and sibling roots seeded with lower-only dependencies")

    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${fixture.v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: real sysupdate installed v2 into the inactive slot")

    target_slot = inactive_slot()
    target_root = "/var/lib/nix-overlay/upper-slots/" + target_slot
    active_before = active_state_checksum()
    failed_generation = None
    cursor = None

    if MODE == "reconcile":
        deployer.succeed("systemctl stop nix-serve.service")
        appliance.fail("systemctl start nixtache-overlay-prepare.service", timeout=900)
        unready = appliance.succeed(
          "grep -l '^state=unready$' " + q(target_root) + "/generations/*/metadata"
        ).strip().splitlines()
        assert unready, "failed preparation produced no unready generation"
        failed_generation = unready[-1][:-len("/metadata")]
        appliance.fail("grep -l '^state=ready$' " + q(target_root) + "/generations/*/metadata")
        appliance.fail("test -e " + q(target_root + "/current") + " || test -L " + q(target_root + "/current"))
        assert active_state_checksum() == active_before, "failed preparation modified the active tree"
        assert_runtime_consumers()
        print("OK: unavailable substituter left the whole generation unready and the active tree unchanged")

        deployer.succeed("systemctl start nix-serve.service")
        deployer.wait_for_unit("nix-serve.service")
        active_before_retry = active_state_checksum()
        cursor = cache_cursor()
        appliance.succeed("systemctl reset-failed nixtache-overlay-prepare.service")
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert active_state_checksum() == active_before_retry, "successful retry modified the active tree"
        appliance.fail("test -e " + q(failed_generation))
        print("OK: retry discarded the unready generation without repairing active state")
    else:
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert active_state_checksum() == active_before, "target wipe modified the active tree"

    assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == target_slot
    target_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
    target = target_root + "/generations/" + target_generation
    appliance.succeed("grep -q '^state=ready$' " + q(target + "/metadata"))
    appliance.succeed("grep -q '^policy=" + MODE + "$' " + q(target + "/metadata"))
    assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == target

    if MODE == "reconcile":
        assert_consumers(target)
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"], target)
        assert_duplicated_metadata(target)
        assert_parent_first_fetches(cursor)
        for case in REPAIR_CASES:
            assert_placement(case["path"], [])
        print("OK: exact target repairs, duplicated metadata and active/cross-sibling isolation verified")
    else:
        assert_empty_tree(target)
        assert_consumers()
        print("WIPE OK: target uppers and upper-owned state are empty with no seeded roots")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    wait_ready_tree()
    assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == target
    print("OK: v2 selected the complete prepared generation and all runtime mounts")

    if MODE == "wipe":
        assert_fixture_absent()
        print("WIPE OK: seeded fixtures and roots stayed absent after reboot")
        for node in NODE_IDS:
            realize(node, CONSUMERS[node])
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"])
        assert_consumers()
        print("WIPE OK: fresh runtime writes landed in their exact layers after reboot")
    else:
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"])
        assert_consumers()
        assert_duplicated_metadata(target)
        print("RECONCILE OK: repaired closures and layer isolation survived cutover")

    assert_runtime_consumers()
    assert_whole_tree()
    print("PASS: overlay-tree topology=" + TOPOLOGY + " upperOnUpdate=" + MODE)
  '';
}

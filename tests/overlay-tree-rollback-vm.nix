{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  topology = "composed";
  upperOnUpdate = "reconcile";
  fixture = import ./overlay-tree-vm-lib.nix {
    inherit nixpkgs self system topology upperOnUpdate appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib;

  canaryModule = {
    services.nixtache.deploy-target.criticalUnits = [
      "nixtache-overlay-tree-rollback-canary.service"
    ];
    systemd.services.nixtache-overlay-tree-rollback-canary = {
      wantedBy = [ "multi-user.target" ];
      after = [ "nixtache-overlay-ready.target" ];
      requires = [ "nixtache-overlay-ready.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "echo 'overlay-tree-rollback-canary: healthy'";
    };
  };

  brokenBootModule = { lib, ... }: {
    services.nixtache.ab-image.ukiTries = 2;
    services.nixtache.deploy-target.healthCheckTimeout = 20;
    systemd.services.nixtache-overlay-tree-rollback-canary.script = lib.mkForce ''
      echo 'overlay-tree-rollback-canary: failing on purpose'
      exit 1
    '';
  };

  mkAppliance = { version, withDependencies ? false, broken ? false }: fixture.mkAppliance {
    inherit version withDependencies;
    extraModules = [ canaryModule ] ++ lib.optional broken brokenBootModule;
  };

  v1 = mkAppliance { version = "1"; withDependencies = true; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  appliances = lib.genAttrs [ "2" ] (version: mkAppliance {
    inherit version;
    broken = version == "2";
  });
  sysupdatePackages = lib.mapAttrs
    (_: appliance: appliance.config.system.build.sysupdate-package)
    appliances;
  sysupdatePackagePaths = lib.mapAttrs (_: package: package.outPath) sysupdatePackages;

  cacheDependencies = builtins.filter
    (package: package.outPath != fixture.v2SysupdatePkg.outPath)
    fixture.deployerDependencies;

  markerPackages = lib.genAttrs fixture.nodeIds (node: pkgs.runCommand
    "overlay-tree-rollback-v2-${node}" { } ''
      printf '%s\n' 'v2:${node}' > $out
    '');
  markerPaths = lib.mapAttrs (_: package: package.outPath) markerPackages;
in
pkgs.testers.runNixOSTest {
  name = "overlay-tree-rollback";
  globalTimeout = 10800;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = cacheDependencies
      ++ builtins.attrValues sysupdatePackages
      ++ builtins.attrValues markerPackages;
  };

  testScript = ''
    import shlex

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
    SYSUPDATE_PACKAGES = ${builtins.toJSON sysupdatePackagePaths}
    MARKERS = ${builtins.toJSON markerPaths}
    NODE_DEPENDENCIES = {
      "host": PATHS["hostDependency"],
      "a": PATHS["sharedDependency"],
      "grand": PATHS["leafDependency"],
      "b": PATHS["commonDependency"],
    }
    CANARY = "nixtache-overlay-tree-rollback-canary.service"
    V2_MARKER_ORDER = []

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

    def inactive_slot():
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=\"$(cat /run/nixtache-overlay/selected-slot)\" "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()

    def selected_generation(slot):
        root = "/var/lib/nix-overlay/upper-slots/" + slot
        selected = appliance.succeed("readlink -f " + q(root + "/current")).strip()
        runtime = appliance.succeed("cat /run/nixtache-overlay/selected-generation").strip()
        assert runtime == selected, f"runtime selection {runtime} does not name the complete current generation {selected}"
        return selected

    def assert_selected_generation(slot, expected):
        assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == slot
        assert selected_generation(slot) == expected, "boot selected a replacement upper generation"

    def db_hashes():
        return {
          node: appliance.succeed(
            "sha256sum " + q(state_path(node) + "/db/db.sqlite") + " | awk '{print $1}'"
          ).strip()
          for node in NODE_IDS
        }

    def db_record_count(node, path, target=None):
        db = state_path(node, target) + "/db/db.sqlite"
        sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
        return appliance.succeed("sqlite3 " + q(db) + " " + q(sql)).strip()

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

    def assert_seeded_roots(target=None):
        for node, path in CONSUMERS.items():
            root = state_path(node, target) + "/gcroots/overlay-tree-" + node
            appliance.succeed("test \"$(readlink " + q(root) + ")\" = " + q(path))
        for root in EXTRA_ROOTS:
            link = state_path(root["node"], target) + "/gcroots/" + root["name"]
            appliance.succeed("test \"$(readlink " + q(link) + ")\" = " + q(root["path"]))

    def assert_db_record(target, node, path):
        count = db_record_count(node, path, target)
        assert count == "1", f"missing duplicated metadata for {path} in {node}: {count}"

    def assert_duplicated_metadata(target):
        assert_db_record(target, "grand", PATHS["sharedConsumer"])
        for node in ("a", "b"):
            assert_db_record(target, node, PATHS["commonDependency"])
        assert_db_record(target, "b", PATHS["hostConsumer"])

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

    def assert_whole_tree(label):
        for node in NODE_IDS:
            listing = "/tmp/overlay-tree-rollback-" + label + "-" + node + "-valid-paths"
            appliance.succeed(nix_cli(node, "path-info --all") + " > " + q(listing), timeout=600)
            root = ROOTS[node].rstrip("/")
            appliance.succeed(
              "while IFS= read -r path; do "
              "test -e " + q(root) + "$path || { echo \"missing whole-tree path at " + node + ": $path\" >&2; exit 1; }; "
              "done < " + q(listing),
              timeout=600,
            )

    def assert_v2_markers_present():
        for node, path in MARKERS.items():
            assert_placement(path, [node])
            root = STATES[node] + "/gcroots/rollback-v2-" + node
            appliance.succeed("test \"$(readlink " + q(root) + ")\" = " + q(path))
            appliance.succeed("grep -Fqx " + q("v2:" + node) + " " + q(fs_path(node, path)))
            assert db_record_count(node, path) == "1", f"v2 marker is not registered at {node}"

    def assert_v2_markers_absent(target=None):
        for owner, path in MARKERS.items():
            assert_placement(path, [], target)
            for node in NODE_IDS:
                root = state_path(node, target) + "/gcroots/rollback-v2-" + owner
                appliance.fail("test -e " + q(root) + " || test -L " + q(root))
                count = db_record_count(node, path, target)
                assert count == "0", f"v2 marker {owner} leaked into the {node} DB"
                if target is None:
                    appliance.fail("test -e " + q(fs_path(node, path)))

    def add_v2_markers():
        for node in reversed(NODE_IDS):
            path = MARKERS[node]
            realize(node, path)
            add_root(node, path, "rollback-v2-" + node)
            appliance.succeed("grep -Fqx " + q("v2:" + node) + " " + q(fs_path(node, path)))
            V2_MARKER_ORDER.append(node)
        assert V2_MARKER_ORDER == list(reversed(NODE_IDS))
        assert_v2_markers_present()
        print("OK: unique v2-only registered markers added in reverse topological order: " + " -> ".join(V2_MARKER_ORDER))

    def wait_tree():
        appliance.wait_until_succeeds("nix --version", timeout=300)
        for unit in MOUNT_UNITS:
            appliance.wait_until_succeeds("systemctl is-active --quiet " + unit, timeout=180)

    def wait_ready_tree():
        appliance.wait_until_succeeds(
          "systemctl is-active --quiet boot-complete.target", timeout=300
        )
        wait_tree()

    def assert_no_reverse_preparation():
        log = appliance.succeed(
          "journalctl -b -u nixtache-overlay-select.service -u nixtache-overlay-prepare.service --no-pager -o cat"
        )
        for marker in ("nixtache-overlay: repairing ", "nixtache-overlay: prepared ", "nixtache-overlay: checking "):
            assert marker not in log, f"rollback ran reverse preparation: {log}"

    def assert_original_v1(label):
        assert appliance.succeed("cat /etc/image-version").strip() == "1"
        wait_tree()
        assert_selected_generation(v1_slot, v1_selected)
        assert_no_reverse_preparation()
        assert_consumers()
        assert_seeded_roots()
        for case in REPAIR_CASES:
            assert_placement(case["path"], [])
        assert_runtime_consumers()
        assert_whole_tree(label)
        assert_v2_markers_absent()
        current_hashes = db_hashes()
        assert current_hashes == v1_db_hashes, f"{label} rollback rewrote v1 DBs: {current_hashes} != {v1_db_hashes}"
        appliance.succeed("systemctl is-active --quiet " + CANARY)

    def stage_and_install(version):
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp " + SYSUPDATE_PACKAGES[version] + "/* /var/lib/nixtache/ab-stage/abtest/"
        )
        appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
        appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_" + version, timeout=900)
        appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_" + version + "+*.efi", timeout=300)
        assert appliance.succeed("cat /etc/image-version").strip() == "1"
        slot = inactive_slot()
        print("OK: real sysupdate installed v" + version + " into inactive slot " + slot)
        return slot

    def prepare_target(version, slot):
        root = "/var/lib/nix-overlay/upper-slots/" + slot
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == slot
        generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        target = root + "/generations/" + generation
        appliance.succeed("grep -q '^state=ready$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^image_version=" + version + "$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^policy=reconcile$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^source_slot=" + v1_slot + "$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^source_generation=" + basename(v1_selected) + "$' " + q(target + "/metadata"))
        assert appliance.succeed("readlink -f " + q(root + "/current")).strip() == target
        assert_selected_generation(v1_slot, v1_selected)
        assert db_hashes() == v1_db_hashes, "target preparation modified the active v1 DBs"
        assert_consumers(target)
        assert_seeded_roots(target)
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"], target)
            assert_placement(case["path"], [])
        assert_duplicated_metadata(target)
        assert_runtime_consumers()
        assert_v2_markers_absent(target)
        assert_v2_markers_absent()
        print("OK: v" + version + " prepared with reconcile from the complete original v1 generation")
        return target

    def assert_v2_boot(boot_number):
        assert appliance.succeed("cat /etc/image-version").strip() == "2", f"boot {boot_number} did not select v2"
        wait_tree()
        assert_selected_generation(v2_slot, v2_target)
        assert_consumers()
        assert_seeded_roots()
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"])
        assert_runtime_consumers()
        remaining_tries = 2 - boot_number
        appliance.succeed("ls /boot/EFI/Linux/abtest_2+" + str(remaining_tries) + "*.efi > /dev/null")
        appliance.wait_until_succeeds("systemctl is-failed --quiet " + CANARY, timeout=60)
        appliance.wait_until_succeeds("systemctl is-failed --quiet nixtache-health-check.service", timeout=120)
        appliance.fail("systemctl is-active --quiet boot-complete.target")
        appliance.wait_until_succeeds(
          "journalctl -u " + CANARY + " -b --no-pager | grep -q 'overlay-tree-rollback-canary: failing on purpose'",
          timeout=60,
        )
        print("OK: v2 boot " + str(boot_number) + " burned a real boot-counting try and remained unblessed")

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
    appliance.succeed("systemctl is-active --quiet " + CANARY)

    for node in NODE_IDS:
        seed_root(node, CONSUMERS[node])
    for root in EXTRA_ROOTS:
        realize(root["node"], root["path"])
        add_root(root["node"], root["path"], root["name"])
    for case in REPAIR_CASES:
        assert_placement(case["path"], [])
    assert_consumers()
    assert_seeded_roots()
    assert_runtime_consumers()
    assert_whole_tree("initial")

    v1_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
    v1_selected = selected_generation(v1_slot)
    v1_db_hashes = db_hashes()
    assert len(set(MARKERS.values())) == len(NODE_IDS)
    print("OK: v1 dependencies stayed in the lower; roots and closures work at host, a, grand and b")
    print("OK: recorded complete v1 generation " + v1_selected + " and all per-node DB hashes")

    v2_slot = stage_and_install("2")
    appliance.succeed("ls /boot/EFI/Linux/abtest_2+2*.efi > /dev/null")
    v2_target = prepare_target("2", v2_slot)

    for boot_number in (1, 2):
        appliance.reboot()
        appliance.wait_for_unit("multi-user.target", timeout=1800)
        assert_v2_boot(boot_number)
        if boot_number == 1:
            assert_v2_markers_absent()
            add_v2_markers()
        else:
            assert_v2_markers_present()

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    appliance.succeed("ls /boot/EFI/Linux/abtest_2+0*.efi > /dev/null")
    assert_original_v1("automatic")
    print("ROLLBACK OK: exhausted v2 selected the exact v1 generation with unchanged DBs, original closures and no v2-only writes or reverse preparation")

    appliance.succeed("mkdir -p /boot/loader/entries")
    appliance.succeed(
      "printf 'title Manual-v1\\nversion 99\\nsort-key abtest\\nuki /EFI/Linux/abtest_1.efi\\n' "
      "> /boot/loader/entries/zz-manual-v1.conf"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert_original_v1("manual")
    print("MANUAL ROLLBACK OK: the v1 loader entry restored the original generation and per-node DBs")
    print("PASS: overlay-tree-rollback topology=composed upperOnUpdate=reconcile automatic+manual")
  '';
}

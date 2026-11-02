{ nixpkgs
, self
, system ? "x86_64-linux"
, failureNode ? "host"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  topology = "composed";
  upperOnUpdate = "reconcile";
  fixture = import ./overlay-tree-vm-lib.nix {
    inherit nixpkgs self system topology upperOnUpdate appliancePkgs;
  };
  inherit (fixture) lib pkgs otaLib;

  shimModule = { config, lib, pkgs, ... }:
    let
      outerPath = builtins.head (lib.splitString " "
        (fixture.mkAppliance { version = "1"; }).config.systemd.services.nixtache-overlay-prepare.script);
      outerText = builtins.readFile outerPath;
      innerPath = builtins.head (lib.splitString "\n"
        (builtins.elemAt (lib.splitString "unshare -m --propagation private " outerText) 1));
      innerText = builtins.readFile innerPath;
      failureFunction = ''
        fail_at() {
          local node=$1 stage=$2
          if [ -r /run/nixtache-overlay-test-failure ] && [ "$(cat /run/nixtache-overlay-test-failure)" = "$stage" ] && [ "$node" = "''${NIXTACHE_TEST_FAILURE_NODE:-}" ]; then
            if [ "$stage" = clone ]; then
              echo "nixtache-overlay-test: clone interruption at $node" >&2
              kill -TERM "$$"
              sleep 1
              exit 143
            fi
            echo "nixtache-overlay-test: $stage failure at $node" >&2
            exit 70
          fi
        }
      '';
      injectedInner = pkgs.writeShellScript "nixtache-overlay-verify-namespace-failure-${failureNode}"
        (builtins.replaceStrings [
          "set -euo pipefail\n"
          "nix-store --option experimental-features \"ca-derivations\" --store \"local?root=$lower_root&state=$stage/host/lower-state\" --load-db < \"$target_dump\""
          "repair_store \"$host_url\" \"$stage/host/state\" \"$host_root\""
          "repair_store \"$node_url\" \"$node_stage/state\" \"$node_root\""
          "check_store \"$host_url\" \"$host_root\""
          "check_store \"$node_url\" \"$node_root\""
        ] [
          "set -euo pipefail\n${failureFunction}"
          "fail_at host seed\nnix-store --option experimental-features \"ca-derivations\" --store \"local?root=$lower_root&state=$stage/host/lower-state\" --load-db < \"$target_dump\""
          "fail_at host repair\nrepair_store \"$host_url\" \"$stage/host/state\" \"$host_root\""
          "fail_at \"$(basename \"$node_stage\")\" repair\nrepair_store \"$node_url\" \"$node_stage/state\" \"$node_root\""
          "fail_at host final\ncheck_store \"$host_url\" \"$host_root\""
          "fail_at \"$(basename \"$node_stage\")\" final\ncheck_store \"$node_url\" \"$node_root\""
        ] innerText);
      injectedOuter = pkgs.writeShellScript "nixtache-overlay-prepare-failure-${failureNode}"
        (builtins.replaceStrings [
          "set -euo pipefail\n"
          "copy_layer \"$source_dir/host\" \"$stage/host\""
          "copy_layer \"$source_path\""
          "unshare -m --propagation private ${innerPath}"
        ] [
          "set -euo pipefail\n${failureFunction}"
          "fail_at host clone\ncopy_layer \"$source_dir/host\" \"$stage/host\""
          "fail_at \"$(basename \"$source_path\")\" clone\ncopy_layer \"$source_path\""
          "unshare -m --propagation private ${injectedInner}"
        ] outerText);
    in
    {
      systemd.services.nixtache-overlay-prepare = {
        script = lib.mkForce "${injectedOuter} --installed";
        serviceConfig.Environment = [ "NIXTACHE_TEST_FAILURE_NODE=${failureNode}" ];
      };
    };

  cacheDependencies = builtins.filter
    (package: package.outPath != fixture.v2SysupdatePkg.outPath)
    fixture.deployerDependencies;

  mkAppliance = { version, withDependencies ? false }: fixture.mkAppliance {
    inherit version withDependencies;
    extraModules = [ shimModule ];
  };

  v1 = mkAppliance { version = "1"; withDependencies = true; };
  appliances = lib.genAttrs [ "2" "3" ] (version: mkAppliance { inherit version; });
  sysupdatePackages = lib.mapAttrs
    (_: appliance: appliance.config.system.build.sysupdate-package)
    appliances;
  sysupdatePackagePaths = lib.mapAttrs (_: package: package.outPath) sysupdatePackages;

  markerVersions = [ "2" ];
  markerPackages = lib.listToAttrs (lib.flatten (map
    (version: map
      (node: lib.nameValuePair "${version}-${node}" (pkgs.runCommand "overlay-tree-slot-reuse-${version}-${node}" { } ''
        printf '%s\n' '${version}:${node}' > $out
      ''))
      fixture.nodeIds)
    markerVersions));
  markerPaths = lib.mapAttrs (_: package: package.outPath) markerPackages;
in
assert lib.assertMsg (builtins.elem failureNode fixture.nodeIds)
  "overlay-tree failureNode must be host, a, grand or b";
pkgs.testers.runNixOSTest {
  name = "overlay-tree-failure-${failureNode}";
  globalTimeout = 10800;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = cacheDependencies
      ++ builtins.attrValues sysupdatePackages
      ++ builtins.attrValues markerPackages;
  };

  testScript = ''
    import re
    import shlex

    FAILURE_NODE = ${builtins.toJSON failureNode}
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
    ACTIVE_MARKERS = []
    FAILED_GENERATIONS = []

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = "${v1.config.system.build.image}/abtest_1.raw"; }}", **kwargs)
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
        archives = ["tar --sort=name --numeric-owner -cf - -C /var/lib/nix-overlay/lower-state ."]
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

    def assert_seeded_roots(target=None):
        for node, path in CONSUMERS.items():
            root = state_path(node, target) + "/gcroots/overlay-tree-" + node
            appliance.succeed("test \"$(readlink " + q(root) + ")\" = " + q(path))
        for root in EXTRA_ROOTS:
            link = state_path(root["node"], target) + "/gcroots/" + root["name"]
            appliance.succeed("test \"$(readlink " + q(link) + ")\" = " + q(root["path"]))

    def assert_db_record(target, node, path):
        db = node_dir(target, node) + "/state/db/db.sqlite"
        sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
        count = appliance.succeed("sqlite3 " + q(db) + " " + q(sql)).strip()
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

    def assert_markers(target=None):
        for version, node, path in ACTIVE_MARKERS:
            assert_placement(path, [node], target)
            root = state_path(node, target) + "/gcroots/slot-reuse-" + version
            appliance.succeed("test \"$(readlink " + q(root) + ")\" = " + q(path))
            content = upper_path(node, path, target) if target is not None else fs_path(node, path)
            appliance.succeed("grep -Fqx " + q(version + ":" + node) + " " + q(content))

    def add_active_writes(version):
        for node in NODE_IDS:
            path = MARKERS[version + "-" + node]
            realize(node, path)
            add_root(node, path, "slot-reuse-" + version)
            appliance.succeed("grep -Fqx " + q(version + ":" + node) + " " + q(fs_path(node, path)))
            ACTIVE_MARKERS.append((version, node, path))
        print("OK: fresh registered slot-reuse writes added at every active node after v" + version)

    def assert_whole_tree():
        for node in NODE_IDS:
            listing = "/tmp/overlay-tree-failure-" + node + "-valid-paths"
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
          "journalctl -n 0 --show-cursor --no-pager"
        ).strip()
        return output.split("cursor:", 1)[1].strip()

    def cache_log(cursor):
        return appliance.succeed(
          "journalctl -u nixtache-overlay-prepare.service --after-cursor=" + q(cursor) + " --no-pager -o cat"
        )

    def marker_positions(log, marker):
        return [match.start() for match in re.finditer(re.escape(marker), log)]

    def assert_parent_first_fetches(cursor):
        log = cache_log(cursor)
        for parent, child in zip(NODE_IDS, NODE_IDS[1:]):
            repair_parent = marker_positions(log, "nixtache-overlay: repairing " + parent)
            prepared_parent = marker_positions(log, "nixtache-overlay: prepared " + parent)
            repair_child = marker_positions(log, "nixtache-overlay: repairing " + child)
            assert repair_parent and prepared_parent and repair_child, (
              f"missing preparation markers for {parent} or {child}"
            )
            assert max(repair_parent) < min(repair_child), (
              f"{parent} repair did not start before {child}"
            )
            assert max(prepared_parent) < min(repair_child), (
              f"{child} repair started before {parent} was prepared"
            )
        checked = [marker_positions(log, "nixtache-overlay: checking " + node) for node in NODE_IDS]
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

    def assert_active_v1_unchanged(active_before):
        assert active_state_checksum() == active_before, "failed preparation modified active files, DB or roots"
        assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == active_slot
        selected = appliance.succeed("readlink -f " + q(active_root + "/current")).strip()
        assert selected == active_generation, "failed preparation changed the active selected generation"
        assert appliance.succeed("cat /etc/image-version").strip() == "1"
        assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == v1_boot_id
        assert_runtime_consumers()
        assert_markers()

    def attempt_failure(mode, version):
        cursor = cache_cursor()
        active_before = active_state_checksum()
        appliance.succeed("printf '%s\\n' " + q(mode) + " > /run/nixtache-overlay-test-failure")
        appliance.succeed("systemctl reset-failed nixtache-overlay-prepare.service || true")
        appliance.fail("systemctl start nixtache-overlay-prepare.service", timeout=900)
        unready = appliance.succeed(
          "grep -l '^state=unready$' " + q(target_root) + "/generations/*/metadata"
        ).strip().splitlines()
        assert unready, mode + " failure produced no unready generation"
        failed_generation = unready[-1][:-len("/metadata")]
        FAILED_GENERATIONS.append(failed_generation)
        appliance.fail("grep -l '^state=ready$' " + q(target_root) + "/generations/*/metadata")
        appliance.fail("test -e " + q(target_root + "/current") + " || test -L " + q(target_root + "/current"))
        assert_active_v1_unchanged(active_before)
        log = cache_log(cursor)
        token = "nixtache-overlay-test: " + mode + (" interruption" if mode == "clone" else " failure") + " at " + FAILURE_NODE
        assert token in log, f"missing injected {mode} failure marker at {FAILURE_NODE}: {log}"
        if mode == "repair":
            assert "nixtache-overlay: repairing " + FAILURE_NODE in log
            assert "nixtache-overlay: prepared " + FAILURE_NODE not in log
        if mode == "final":
            assert "nixtache-overlay: prepared " + FAILURE_NODE in log
            assert "nixtache-overlay: checking " + FAILURE_NODE in log
        print("OK: v" + version + " " + mode + " failure at " + FAILURE_NODE + " stayed unready; active v1 files, DB, roots and closures survived")

    def complete_preparation(version):
        active_before_success = active_state_checksum()
        cursor = cache_cursor()
        appliance.succeed("printf '%s\\n' none > /run/nixtache-overlay-test-failure")
        appliance.succeed("systemctl reset-failed nixtache-overlay-prepare.service || true")
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert active_state_checksum() == active_before_success, "successful retry modified the active tree"
        assert_runtime_consumers()
        assert_markers()
        for failed_generation in FAILED_GENERATIONS:
            appliance.fail("test -e " + q(failed_generation))
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == target_slot
        target_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        target = target_root + "/generations/" + target_generation
        appliance.succeed("grep -q '^state=ready$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^image_version=" + version + "$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^policy=reconcile$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^source_slot=" + str(active_slot) + "$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^source_generation=" + basename(active_generation) + "$' " + q(target + "/metadata"))
        assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == target
        assert_consumers(target)
        assert_seeded_roots(target)
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"], target)
            if version == "2":
                assert_placement(case["path"], [])
        assert_duplicated_metadata(target)
        assert_markers(target)
        assert_parent_first_fetches(cursor)
        print("OK: successful v" + version + " preparation discarded every unready generation and preserved active state")
        return target

    def assert_booted_target(version, target):
        assert appliance.succeed("cat /etc/image-version").strip() == version
        wait_ready_tree()
        assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == target_slot
        assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == target
        assert_consumers()
        assert_seeded_roots()
        for case in REPAIR_CASES:
            assert_placement(case["path"], case["nodes"])
        assert_duplicated_metadata(target)
        assert_markers()
        assert_runtime_consumers()
        assert_whole_tree()
        print("OK: post-reboot v" + version + " selected the complete reused-slot generation")

    def stage_and_install(version, allow_new_slot=False, expected_version="1"):
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp " + SYSUPDATE_PACKAGES[version] + "/* /var/lib/nixtache/ab-stage/abtest/"
        )
        appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
        appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_" + version, timeout=900)
        appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_" + version + "+*.efi", timeout=300)
        assert appliance.succeed("cat /etc/image-version").strip() == expected_version
        if expected_version == "1":
            assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == v1_boot_id
        else:
            assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() != v1_boot_id
        global target_slot, target_root
        installed_target = inactive_slot()
        if target_slot is None or allow_new_slot:
            target_slot = installed_target
            target_root = "/var/lib/nix-overlay/upper-slots/" + target_slot
        else:
            assert installed_target == target_slot, "sysupdate did not reuse the original physical target slot"
        print("OK: real sysupdate staged v" + version + " into target slot " + target_slot + " while active v" + expected_version + " remained running")

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
    v1_boot_id = appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    active_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
    active_root = "/var/lib/nix-overlay/upper-slots/" + active_slot
    active_generation = appliance.succeed("readlink -f " + q(active_root + "/current")).strip()
    target_slot = None
    target_root = ""
    print("OK: v1 composed appliance booted with dependencies only in its lower")

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
    print("OK: composed roots seeded at host, intermediate, grandchild and sibling nodes")

    stage_and_install("2")
    if FAILURE_NODE == "host":
        attempt_failure("seed", "2")
    else:
        print("OK: seed=N/A for non-host failure node " + FAILURE_NODE)
    attempt_failure("clone", "2")
    attempt_failure("repair", "2")
    attempt_failure("final", "2")
    add_active_writes("2")
    target = complete_preparation("2")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert_booted_target("2", target)
    active_slot = target_slot
    active_generation = target

    stage_and_install("3", allow_new_slot=True, expected_version="2")
    target = complete_preparation("3")
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    assert_booted_target("3", target)
    print("PASS: overlay-tree-failure node=" + FAILURE_NODE + " topology=composed upperOnUpdate=reconcile seed=" + ("covered" if FAILURE_NODE == "host" else "N/A"))
  '';
}

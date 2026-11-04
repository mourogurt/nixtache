{ nixpkgs
, self
, system ? "x86_64-linux"
, scenario ? "reconcile"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  scenarios = [ "reconcile" "wipe" "storage-reset" "descriptor-missing" "descriptor-mismatch" ];
  policy = if scenario == "wipe" then "wipe" else "reconcile";
  storageReset = scenario == "storage-reset";
  descriptorFailure = if scenario == "descriptor-missing" then "missing"
    else if scenario == "descriptor-mismatch" then "mismatch"
    else null;
  overlayBase = "/var/lib/nix-overlay";
  hostUpper = "${overlayBase}/upper";
  hostWork = "${overlayBase}/work";
  slotsDir = "${overlayBase}/upper-slots";
  topologyBase = "${overlayBase}/topology";
  physicalLower = "/run/nixtache-overlay-topology/physical";
  seedNodes = [ "b" "e" ];
  sourceLayer = id: {
    inherit id;
    parent = null;
    upperDir = "${topologyBase}/${id}/upper";
    workDir = "${topologyBase}/${id}/work";
    stateDir = "${topologyBase}/${id}/state";
    lowerRoot = "/run/nixtache-overlay-topology/lower/${id}";
  };
  sourceLayers = map sourceLayer [ "b" "e" "old" ];
  targetB = (sourceLayer "b") // lib.optionalAttrs storageReset {
    upperDir = "${topologyBase}/b-reset/upper";
    stateDir = "${topologyBase}/b-reset/state";
  };
  targetLayers = [
    targetB
    ((sourceLayer "c") // { parent = "b"; })
    ((sourceLayer "d") // { parent = "b"; })
    ((sourceLayer "e") // { parent = "b"; })
  ];
  sourceRoot = id: "${topologyBase}/${id}/root";
  sourceUnit = "nixtache-overlay-topology-source-stores.service";
  runtimeModule = isSource: { lib, pkgs, ... }: {
    services.nixtache.overlay-nix = {
      enable = true;
      upperDir = hostUpper;
      workDir = hostWork;
      upperOnUpdate = policy;
      _layers = if isSource then sourceLayers else targetLayers;
    };
    environment.systemPackages = [ pkgs.sqlite ];
    systemd.services.nixtache-overlay-topology-source-stores = lib.mkIf isSource {
      description = "Mount the source-only sibling stores used to seed topology consumers";
      wantedBy = [ "nixtache-overlay-ready.target" ];
      before = [ "nixtache-overlay-ready.target" ];
      after = [ "nixtache-overlay-select.service" ];
      requires = [ "nixtache-overlay-select.service" ];
      path = with pkgs; [ coreutils util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p ${physicalLower}/nix/store
        if ! mountpoint -q ${physicalLower}/nix/store; then
          mount -o ro "/dev/disk/by-partuuid/$(cat /run/nixtache-overlay/selected-slot)" ${physicalLower}/nix/store
        fi
        ${lib.concatMapStrings (id: ''
          mkdir -p ${sourceRoot id}/nix/store ${topologyBase}/${id}/upper ${topologyBase}/${id}/work ${topologyBase}/${id}/state
          if ! mountpoint -q ${sourceRoot id}/nix/store; then
            mount -t overlay overlay -o lowerdir=${hostUpper}:${physicalLower}/nix/store,upperdir=${topologyBase}/${id}/upper,workdir=${topologyBase}/${id}/work ${sourceRoot id}/nix/store
          fi
        '') seedNodes}
      '';
    };
    systemd.targets.nixtache-overlay-ready = lib.mkIf isSource {
      after = [ sourceUnit ];
      requires = [ sourceUnit ];
    };
  };
  mkAppliance = { version, isSource }: otaLib.mkAppliance {
    inherit version;
    storeSize = "1G";
    extraModules = [
      self.nixosModules.overlay-nix
      (runtimeModule isSource)
    ];
  };
  v1 = mkAppliance { version = "1"; isSource = true; };
  v2 = mkAppliance { version = "2"; isSource = false; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2SysupdatePkg = v2.config.system.build.sysupdate-package;
  targetLogical = v2.config.services.nixtache.overlay-nix._topology.descriptor;
  bConsumer = pkgs.runCommand "overlay-topology-b-consumer" { } ''
    printf 'b consumer\n' > $out
  '';
  eConsumer = pkgs.runCommand "overlay-topology-e-consumer" { } ''
    printf 'e consumer\n' > $out
  '';
  encodeStoreUri = value: lib.replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ] value;
  hostLower = "local?state=${overlayBase}/lower-state&read-only=true";
  hostStoreUrl = "local-overlay://?root=/&state=/nix/var/nix"
    + "&lower-store=${encodeStoreUri hostLower}"
    + "&upper-layer=${hostUpper}"
    + "&ignore-gc-delete-failure=true&check-mount=false";
  sourceStoreUrls = lib.genAttrs seedNodes (id:
    "local-overlay://?root=${sourceRoot id}&state=${topologyBase}/${id}/state"
    + "&lower-store=${encodeStoreUri hostStoreUrl}"
    + "&upper-layer=${topologyBase}/${id}/upper"
    + "&ignore-gc-delete-failure=true&check-mount=false"
  );
in
assert lib.assertMsg (builtins.elem scenario scenarios)
  "overlay-topology-operations-vm scenario must be one of ${lib.concatStringsSep ", " scenarios}";
pkgs.testers.runNixOSTest {
  name = "overlay-topology-operations-${scenario}";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = [ v2SysupdatePkg bConsumer eConsumer ];
  };

  testScript = ''
    import json
    import shlex

    SCENARIO = ${builtins.toJSON scenario}
    POLICY = ${builtins.toJSON policy}
    STORAGE_RESET = ${if storageReset then "True" else "False"}
    DESCRIPTOR_FAILURE = ${if descriptorFailure == null then "None" else builtins.toJSON descriptorFailure}
    SLOTS = ${builtins.toJSON slotsDir}
    TARGET_LOGICAL = json.loads(${builtins.toJSON (builtins.toJSON targetLogical)})
    CONSUMERS = ${builtins.toJSON { b = bConsumer.outPath; e = eConsumer.outPath; }}
    STORES = ${builtins.toJSON sourceStoreUrls}
    EXPECTED_OPERATIONS = {
      "host": "unchanged",
      "b": "storage-reset" if STORAGE_RESET else "promote",
      "e": "reparent",
      "old": "remove",
      "c": "add",
      "d": "add",
    }
    EXPECTED_DISPOSITIONS = {
      "host-lower": "freeze",
      "host-runtime": "empty" if POLICY == "wipe" else "empty-continuation",
      "b-lower": "freeze",
      "b-runtime": "empty" if POLICY == "wipe" or STORAGE_RESET else "empty-continuation",
      "c": "empty",
      "d": "empty",
      "e": "empty" if POLICY == "wipe" else "clone-and-repair",
    }
    EXPECTED_PHYSICAL = [
      {"id": "host-lower", "logicalId": "host", "role": "frozen-lower", "parent": None},
      {"id": "host-runtime", "logicalId": "host", "role": "runtime", "parent": "host-lower"},
      {"id": "b-lower", "logicalId": "b", "role": "frozen-lower", "parent": "host-lower"},
      {"id": "b-runtime", "logicalId": "b", "role": "runtime", "parent": "b-lower"},
      {"id": "c", "logicalId": "c", "role": "runtime", "parent": "b-lower"},
      {"id": "d", "logicalId": "d", "role": "runtime", "parent": "b-lower"},
      {"id": "e", "logicalId": "e", "role": "runtime", "parent": "b-lower"},
    ]
    EXPECTED_CONSUMERS = {
      "host": "host-runtime",
      "b": "b-runtime",
      "c": "c",
      "d": "d",
      "e": "e",
    }

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def q(value):
        return shlex.quote(value)

    def basename(path):
        return path.rsplit("/", 1)[-1]

    def nix_store(node, args):
        features = "ca-derivations local-overlay-store read-only-local-store"
        return "nix-store --option experimental-features " + q(features) + " --store " + q(STORES[node]) + " " + args

    def seed_consumer(node, path):
        appliance.succeed(nix_store(node, "--realize " + q(path)), timeout=600)
        state = ${builtins.toJSON topologyBase} + "/" + node + "/state"
        appliance.succeed(
          "mkdir -p " + q(state + "/gcroots") + " && ln -sfn " + q(path) + " " + q(state + "/gcroots/source-" + node)
        )
        appliance.succeed(nix_store(node, "-q --requisites " + q(path)), timeout=300)

    def tree_checksum(path):
        return appliance.succeed(
          "tar --sort=name --numeric-owner -cf - -C " + q(path) + " . | sha256sum | awk '{print $1}'"
        ).strip()

    def node_dir(target, physical_id):
        return target + ("/host" if physical_id == "host-runtime" else "/nodes/" + physical_id)

    def upper_marker(directory, path):
        return directory + "/upper/" + basename(path)

    def root_marker(directory, logical_id):
        return directory + "/state/gcroots/source-" + logical_id

    def db_count(directory, path):
        db = directory + "/state/db/db.sqlite"
        exists = appliance.succeed("if test -f " + q(db) + "; then echo yes; else echo no; fi").strip() == "yes"
        if not exists:
            return "0"
        sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
        return appliance.succeed("sqlite3 " + q(db) + " " + q(sql)).strip()

    def assert_consumer(directory, logical_id):
        path = CONSUMERS[logical_id]
        appliance.succeed("test -f " + q(upper_marker(directory, path)))
        appliance.succeed("test -L " + q(root_marker(directory, logical_id)))
        assert appliance.succeed("readlink " + q(root_marker(directory, logical_id))).strip() == path
        assert db_count(directory, path) == "1", f"missing validity record for {logical_id} in {directory}"

    def assert_consumer_absent(directory, logical_id):
        path = CONSUMERS[logical_id]
        appliance.fail("test -e " + q(upper_marker(directory, path)) + " || test -L " + q(upper_marker(directory, path)))
        appliance.fail("test -e " + q(root_marker(directory, logical_id)) + " || test -L " + q(root_marker(directory, logical_id)))
        assert db_count(directory, path) == "0", f"unexpected validity record for {logical_id} in {directory}"

    def assert_empty_node(directory):
        appliance.succeed("test -d " + q(directory + "/upper") + " && test -d " + q(directory + "/state"))
        appliance.fail("find " + q(directory + "/upper") + " -mindepth 1 -print -quit | grep -q .")
        appliance.fail(
          "(find " + q(directory + "/state/gcroots") + " " + q(directory + "/state/profiles") + " " +
          q(directory + "/state/temproots") + " -type l -print 2>/dev/null || true) | grep -q ."
        )
        db = directory + "/state/db/db.sqlite"
        appliance.succeed(
          "if test -f " + q(db) + "; then test \"$(sqlite3 " + q(db) + " " +
          q("SELECT COUNT(*) FROM ValidPaths;") + ")\" = 0; fi"
        )

    def inactive_slot(active_slot):
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | awk -v active=" + q(active_slot) + " "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active {print tolower($1); exit}'"
        ).strip()

    def assert_active_unchanged(active_slot, active_current, active_source, active_checksum):
        assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == active_slot
        assert appliance.succeed("readlink -f " + q(active_current)).strip() == active_source
        assert tree_checksum(active_source) == active_checksum, "active source generation changed"
        assert_consumer(active_source + "/nodes/b", "b")
        assert_consumer(active_source + "/nodes/e", "e")

    def assert_no_publication(target_root, active_slot, active_source):
        appliance.fail("test -e " + q(target_root + "/current") + " || test -L " + q(target_root + "/current"))
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == active_slot
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip() == basename(active_source)
        appliance.fail("find " + q(target_root + "/generations") + " -mindepth 1 -print -quit 2>/dev/null | grep -q .")
        appliance.fail("find " + q(target_root) + " -maxdepth 1 -name '.staging-*' -print -quit | grep -q .")

    def metadata(path):
        result = {}
        for line in appliance.succeed("cat " + q(path)).splitlines():
            key, value = line.split("=", 1)
            result[key] = value
        return result

    def listing(path):
        output = appliance.succeed(
          "find " + q(path) + " -mindepth 1 -maxdepth 1 -printf '%f\\n' | sort"
        ).strip()
        return [] if not output else output.splitlines()

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target", timeout=1800)
    appliance.wait_until_succeeds("systemctl is-active --quiet boot-complete.target", timeout=300)
    appliance.wait_until_succeeds("systemctl is-active --quiet " + ${builtins.toJSON sourceUnit}, timeout=300)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"

    for node, path in CONSUMERS.items():
        seed_consumer(node, path)

    active_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
    active_current = SLOTS + "/" + active_slot + "/current"
    active_source = appliance.succeed("readlink -f " + q(active_current)).strip()
    assert_consumer(active_source + "/nodes/b", "b")
    assert_consumer(active_source + "/nodes/e", "e")
    active_checksum = tree_checksum(active_source)
    print("OK: rooted b/e consumers seeded through source-only stores")

    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && cp ${v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_fails("systemctl is-active --quiet systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=300)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    appliance.succeed("${otaLib.assertSysupdateInstalled}")
    target_descriptor = "/boot/EFI/nixtache/abtest_2.overlay-topology.json"
    target_lower = "/boot/EFI/nixtache/abtest_2.lower-db"
    appliance.succeed("test -f " + q(target_descriptor) + " && test -f " + q(target_lower))
    target_slot = inactive_slot(active_slot)
    assert target_slot and target_slot != active_slot
    target_root = SLOTS + "/" + target_slot
    print("OK: real sysupdate installed the v2 lower and target descriptor")

    if DESCRIPTOR_FAILURE == "missing":
        appliance.succeed("rm " + q(target_descriptor))
    elif DESCRIPTOR_FAILURE == "mismatch":
        appliance.succeed(
          "sed -E 's/\"lowerDbSha256\":\"[0-9a-f]{64}\"/\"lowerDbSha256\":\"" +
          "0" * 64 + "\"/' " + q(target_descriptor) + " > /tmp/overlay-topology-mismatch.json && "
          "cp /tmp/overlay-topology-mismatch.json " + q(target_descriptor)
        )

    if DESCRIPTOR_FAILURE is not None:
        appliance.fail("systemctl start nixtache-overlay-prepare.service", timeout=900)
        expected_error = (
          "target topology descriptor is missing: " + target_descriptor
          if DESCRIPTOR_FAILURE == "missing"
          else "does not match the target lower dump"
        )
        appliance.succeed(
          "journalctl -u nixtache-overlay-prepare.service --no-pager -o cat | grep -F " + q(expected_error)
        )
        assert_no_publication(target_root, active_slot, active_source)
        assert_active_unchanged(active_slot, active_current, active_source, active_checksum)
        print("PASS: " + SCENARIO + " rejected v2 before publication and preserved the active source")
    else:
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == target_slot
        target_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        target = target_root + "/generations/" + target_generation
        assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == target
        assert_active_unchanged(active_slot, active_current, active_source, active_checksum)

        descriptor = json.loads(appliance.succeed("cat " + q(target_descriptor)))
        published_descriptor = json.loads(appliance.succeed("cat " + q(target + "/overlay-topology.json")))
        plan = json.loads(appliance.succeed("cat " + q(target + "/plan.json")))
        assert descriptor["logicalTopology"] == TARGET_LOGICAL
        assert published_descriptor == descriptor
        assert plan["schema"] == "nixtache.overlay-plan/v1"
        assert plan["imageId"] == descriptor["imageId"] == "abtest"
        assert plan["imageVersion"] == descriptor["imageVersion"] == "2"
        assert plan["lowerDbSha256"] == descriptor["lowerDbSha256"]
        assert plan["logicalTopology"] == descriptor["logicalTopology"]
        assert plan["policy"] == POLICY
        assert plan["sourceCompatibility"] == "descriptor"
        assert plan["operations"] == EXPECTED_OPERATIONS
        assert plan["dispositions"] == EXPECTED_DISPOSITIONS
        assert plan["consumerNodeByLogical"] == EXPECTED_CONSUMERS
        assert plan["frozenLowerByLogical"] == {"host": "host-lower", "b": "b-lower"}
        actual_physical = [
          {key: node.get(key) for key in ("id", "logicalId", "role", "parent")}
          for node in plan["physical"]["nodes"]
        ]
        assert actual_physical == EXPECTED_PHYSICAL
        assert listing(target + "/nodes") == sorted(node["id"] for node in EXPECTED_PHYSICAL)
        assert listing(target + "/layers") == ["b", "c", "d", "e"]

        for logical_id, physical_id in EXPECTED_CONSUMERS.items():
            if logical_id == "host":
                assert appliance.succeed("readlink " + q(target + "/nodes/host-runtime")).strip() == "../host"
            else:
                alias = target + "/layers/" + logical_id
                assert appliance.succeed("readlink " + q(alias)).strip() == "../nodes/" + physical_id
        appliance.fail("test -e " + q(target + "/layers/old") + " || test -L " + q(target + "/layers/old"))
        appliance.fail("test -e " + q(target + "/nodes/old") + " || test -L " + q(target + "/nodes/old"))

        lower_sha = appliance.succeed("sha256sum " + q(target_lower) + " | awk '{print $1}'").strip()
        descriptor_sha = appliance.succeed("sha256sum " + q(target_descriptor) + " | awk '{print $1}'").strip()
        published_descriptor_sha = appliance.succeed(
          "sha256sum " + q(target + "/overlay-topology.json") + " | awk '{print $1}'"
        ).strip()
        assert descriptor_sha == published_descriptor_sha
        assert plan["lowerDbSha256"] == lower_sha
        meta = metadata(target + "/metadata")
        assert meta["slot"] == target_slot
        assert meta["image_id"] == "abtest"
        assert meta["image_version"] == "2"
        assert meta["lower_sha256"] == lower_sha
        assert meta["descriptor_sha256"] == descriptor_sha
        assert meta["policy"] == POLICY
        assert meta["topology"] == ",".join(TARGET_LOGICAL["order"])
        assert meta["topology_sha256"] == TARGET_LOGICAL["fingerprint"]
        assert meta["graph_sha256"] == plan["generationFingerprint"]
        assert meta["source_slot"] == active_slot
        assert meta["source_generation"] == basename(active_source)
        assert meta["generation"] == target_generation
        assert meta["state"] == "ready"

        if POLICY == "wipe":
            for node in EXPECTED_PHYSICAL:
                directory = node_dir(target, node["id"])
                assert_empty_node(directory)
                for logical_id in CONSUMERS:
                    assert_consumer_absent(directory, logical_id)
        else:
            for node in EXPECTED_PHYSICAL:
                directory = node_dir(target, node["id"])
                for logical_id in CONSUMERS:
                    retained = (node["id"] == "b-lower" and logical_id == "b" and not STORAGE_RESET) or (
                      node["id"] == "e" and logical_id == "e"
                    )
                    if retained:
                        assert_consumer(directory, logical_id)
                    else:
                        assert_consumer_absent(directory, logical_id)
            assert_empty_node(target + "/nodes/b-runtime")
            assert_empty_node(target + "/nodes/c")
            assert_empty_node(target + "/nodes/d")
            if STORAGE_RESET:
                assert_empty_node(target + "/nodes/b-lower")
        print("PASS: " + SCENARIO + " published the exact v2 graph with the required state disposition")
  '';
}

{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  oracle = import ./runner-topology-oracle.nix { inherit lib; };

  cacheKey = pkgs.runCommand "runner-topology-cache-key" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export NIX_STATE_DIR=$TMPDIR/nix-state
    mkdir -p $out "$NIX_STATE_DIR"
    nix-store --generate-binary-cache-key runner-topology-local $out/private $out/public
  '';
  cachePub = builtins.readFile "${cacheKey}/public";

  containersFor = state: lib.mapAttrs
    (_: declaration: {
      inherit (declaration) enable containerName;
      store = {
        inherit (declaration) parent mode path hostBackup;
      };
    })
    state;

  runnerIds = state: builtins.filter
    (id: state.${id}.enable && state.${id}.path != "/" && state.${id}.mode == "overlay")
    (builtins.attrNames state);

  pythonRunners = state: lib.genAttrs (runnerIds state) (id:
    let declaration = state.${id}; in
    {
      inherit (declaration) parent path hostBackup containerName;
      lowerRoot = "/run/nixtache-runner-lower/${id}";
      socket = "unix://${declaration.path}/nix/var/nix/daemon-socket/socket";
    });

  mkAppliance =
    { version
    , state
    , policy ? "reconcile"
    , brokenBoot ? false
    , lowerDependencies ? [ ]
    }:
    otaLib.mkAppliance {
      inherit version;
      storeSize = "2G";
      extraPackages = [ pkgs.sqlite ];
      extraModules = [
        self.nixosModules.runner
        self.nixosModules.overlay-nix
        ({ lib, ... }:
          let
            containerUnits = map
              (id: "container@${state.${id}.containerName}.service")
              (builtins.attrNames state);
          in
          {
            services.nixtache.runner = {
              enable = true;
              forgejoUrl = "http://localhost:3000";
              cache.enable = false;
              secrets.cachePrivateKey = /dev/null;
              containers = containersFor state;
              enableSandbox = false;
              additionalCapabilities = [ "CAP_SYS_ADMIN" ];
              nixSettings = {
                substituters = lib.mkForce [ "http://deployer:5000" ];
                trusted-public-keys = lib.mkForce [ cachePub ];
                max-jobs = 1;
                cores = 2;
              };
            };
            services.nixtache.overlay-nix = {
              enable = true;
              upperOnUpdate = policy;
            };
            nix.settings = {
              substituters = lib.mkForce [ "http://deployer:5000" ];
              trusted-public-keys = lib.mkForce [ cachePub ];
            };
            system.extraDependencies = lowerDependencies;
            services.nixtache.ab-image.ukiTries = lib.mkIf brokenBoot 2;
            services.nixtache.deploy-target = {
              criticalUnits = [ "nixtache-runner-topology-canary.service" ];
              healthCheckTimeout = lib.mkIf brokenBoot 20;
            };
            systemd.services.nixtache-runner-topology-canary = {
              wantedBy = [ "multi-user.target" ];
              after = [ "nixtache-overlay-ready.target" ] ++ containerUnits;
              requires = [ "nixtache-overlay-ready.target" ] ++ containerUnits;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = if brokenBoot then "exit 1" else ":";
            };
          })
      ];
    };

  deployerNode = dependencies: { lib, ... }: {
    imports = [ (otaLib.deployerNode { extraDependencies = dependencies; }) ];
    services.nix-serve.secretKeyFile = lib.mkForce "${cacheKey}/private";
  };

  markerPackages = prefix: ids: lib.genAttrs ids (id:
    pkgs.runCommand "${prefix}-${id}" { } ''
      printf '%s\n' '${prefix}:${id}' > $out
    '');

  consumerPackages = prefix: ids:
    let
      dependencies = lib.genAttrs ids (id:
        pkgs.runCommand "${prefix}-dependency-${id}" { } ''
          printf '%s\n' '${prefix}:dependency:${id}' > $out
        '');
      consumers = lib.genAttrs ids (id:
        pkgs.runCommand "${prefix}-consumer-${id}" { } ''
          printf '%s\n%s\n' '${prefix}:consumer:${id}' '${dependencies.${id}}' > $out
        '');
    in
    {
      inherit dependencies consumers;
      dependencyPaths = lib.mapAttrs (_: package: package.outPath) dependencies;
      consumerPaths = lib.mapAttrs (_: package: package.outPath) consumers;
      allPackages = builtins.attrValues dependencies ++ builtins.attrValues consumers;
    };

  packagePaths = packages: lib.mapAttrs (_: package: package.outPath) packages;

  pythonHelpers = ''
    def q(value):
        return shlex.quote(value)

    def basename(path):
        return path.rsplit("/", 1)[-1]

    def crun(node, inner):
        return appliance.succeed(
          "nixos-container run " + q(RUNNERS[node]["containerName"]) +
          " -- /bin/sh -c " + q(inner)
        )

    def cfail(node, inner):
        return appliance.fail(
          "nixos-container run " + q(RUNNERS[node]["containerName"]) +
          " -- /bin/sh -c " + q(inner)
        )

    def merged_path(node, path):
        return RUNNERS[node]["path"] + "/nix/store/" + basename(path)

    def assert_merged(node, path, expected=True):
        if expected:
            crun(node, "test -f " + q(merged_path(node, path)))
        else:
            crun(node, "test ! -e " + q(merged_path(node, path)) + " && test ! -L " + q(merged_path(node, path)))

    def path_info(node, path):
        crun(node,
          "nix --extra-experimental-features 'nix-command ca-derivations local-overlay-store read-only-local-store' " +
          "path-info --store " + q(RUNNERS[node]["socket"]) + " " + q(path)
        )

    def path_absent(node, path):
        cfail(node,
          "nix --extra-experimental-features 'nix-command ca-derivations local-overlay-store read-only-local-store' " +
          "path-info --store " + q(RUNNERS[node]["socket"]) + " " + q(path)
        )

    def realize(node, path):
        crun(node,
          "nix-store --option experimental-features 'ca-derivations local-overlay-store read-only-local-store' " +
          "--store " + q(RUNNERS[node]["socket"]) + " --realize " + q(path)
        )
        state = RUNNERS[node]["path"] + "/nix/var/nix"
        crun(node,
          "mkdir -p " + q(state + "/gcroots") + " && ln -sfn " + q(path) + " " +
          q(state + "/gcroots/runner-topology-" + node)
        )

    def realize_host(path):
        appliance.succeed("nix-store --realize " + q(path), timeout=600)
        appliance.succeed(
          "mkdir -p /nix/var/nix/gcroots && ln -sfn " + q(path) + " /nix/var/nix/gcroots/runner-topology-host"
        )

    def build_proof(node, label):
        builder = crun(node, "readlink -f /bin/sh").strip()
        output = crun(node,
          "nix --extra-experimental-features nix-command build --no-link --print-out-paths " +
          "--store " + q(RUNNERS[node]["socket"]) + " --option sandbox false --option substitute false " +
          "--expr 'derivation { name = \"runner-topology-" + label + "\"; " +
          "system = \"${system}\"; builder = \"" + builder + "\"; " +
          "args = [ \"-c\" \"echo " + label + " > $out\" ]; }' 2>&1"
        ).strip().splitlines()[-1]
        assert "runner-topology-" + label in output, f"unexpected build output: {output!r}"
        return output

    def node_dir(target, physical_id):
        return target + ("/host" if physical_id == "host-runtime" else "/nodes/" + physical_id)

    def consumer_dir(target, logical_id):
        return node_dir(target, EXPECTED_GRAPH["consumerNodeByLogical"][logical_id])

    def upper_marker(directory, path):
        return directory + "/upper/" + basename(path)

    def runtime_upper(node):
        return RUNNERS[node]["hostBackup"] + "/overlay/upper"

    def runtime_state(node):
        return RUNNERS[node]["hostBackup"] + "/nix/var/nix"

    def assert_runtime_upper(node, path, expected=True):
        candidate = runtime_upper(node) + "/" + basename(path)
        if expected:
            appliance.succeed("test -f " + q(candidate))
        else:
            appliance.fail("test -e " + q(candidate) + " || test -L " + q(candidate))

    def assert_db_record(directory, path, expected=True):
        db = directory + "/state/db/db.sqlite"
        sql = "SELECT COUNT(*) FROM ValidPaths WHERE path = '" + path + "';"
        count = appliance.succeed(
          "if test -f " + q(db) + "; then sqlite3 " + q(db) + " " + q(sql) + "; else echo 0; fi"
        ).strip()
        assert count == ("1" if expected else "0"), f"unexpected validity count for {path} in {db}: {count}"

    def assert_consumer(directory, logical_id, path):
        appliance.succeed("test -f " + q(upper_marker(directory, path)))
        root = directory + "/state/gcroots/runner-topology-" + logical_id
        if logical_id == "host":
            root = directory + "/state/gcroots/runner-topology-host"
        appliance.succeed("test -L " + q(root))
        assert appliance.succeed("readlink " + q(root)).strip() == path
        assert_db_record(directory, path)

    def assert_consumer_absent(directory, logical_id, path):
        appliance.fail("test -e " + q(upper_marker(directory, path)) + " || test -L " + q(upper_marker(directory, path)))
        root = directory + "/state/gcroots/runner-topology-" + logical_id
        if logical_id == "host":
            root = directory + "/state/gcroots/runner-topology-host"
        appliance.fail("test -e " + q(root) + " || test -L " + q(root))
        assert_db_record(directory, path, expected=False)

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

    def tree_checksum(path):
        return appliance.succeed(
          "tar --sort=name --numeric-owner -cf - -C " + q(path) + " . | sha256sum | awk '{print $1}'"
        ).strip()

    def inactive_slot():
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=\"$(cat /run/nixtache-overlay/selected-slot)\" "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()

    def selected_generation():
        slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        current = appliance.succeed(
          "readlink -f /var/lib/nix-overlay/upper-slots/" + slot + "/current"
        ).strip()
        runtime = appliance.succeed("cat /run/nixtache-overlay/selected-generation").strip()
        assert runtime == current, f"runtime selection {runtime} differs from current {current}"
        return current

    def graph_projection(plan):
        return {
          "nodes": plan["nodes"],
          "order": plan["order"],
          "physical": {
            "nodes": [
              {key: node.get(key) for key in ("id", "logicalId", "role", "parent")}
              for node in plan["physical"]["nodes"]
            ],
            "order": plan["physical"]["order"],
          },
          "consumerNodeByLogical": plan["consumerNodeByLogical"],
          "frozenLowerByLogical": plan["frozenLowerByLogical"],
          "lineageByPhysical": plan["lineageByPhysical"],
          "generationFingerprint": plan["generationFingerprint"],
          "operations": plan["operations"],
          "dispositions": plan["dispositions"],
        }

    def assert_plan(target):
        plan = json.loads(appliance.succeed("cat " + q(target + "/plan.json")))
        assert graph_projection(plan) == EXPECTED_GRAPH, "published plan differs from the independent operation oracle"
        assert plan["policy"] == POLICY
        appliance.succeed("grep -q '^state=ready$' " + q(target + "/metadata"))
        appliance.succeed("grep -q '^policy=" + POLICY + "$' " + q(target + "/metadata"))
        physical_ids = {node["id"] for node in EXPECTED_GRAPH["physical"]["nodes"]}
        for physical_id in physical_ids:
            if physical_id == "host-runtime":
                appliance.succeed("test -L " + q(target + "/nodes/host-runtime"))
            else:
                appliance.succeed("test -d " + q(target + "/nodes/" + physical_id))
        for logical_id, physical_id in EXPECTED_GRAPH["consumerNodeByLogical"].items():
            if logical_id != "host":
                alias = target + "/layers/" + logical_id
                assert appliance.succeed("readlink " + q(alias)).strip() == "../nodes/" + physical_id
        return plan

    def wait_graph(blessed=True):
        appliance.wait_until_succeeds(
          "systemctl is-active --quiet nixtache-overlay-ready.target", timeout=600
        )
        if blessed:
            appliance.wait_until_succeeds("systemctl is-active --quiet boot-complete.target", timeout=300)
        for physical_id in set(EXPECTED_GRAPH["frozenLowerByLogical"].values()):
            unit = "nixtache-overlay-frozen-" + physical_id + ".service"
            appliance.wait_until_succeeds("systemctl is-active --quiet " + unit, timeout=300)
        selected = selected_generation()
        for node, settings in RUNNERS.items():
            unit = "container@" + settings["containerName"] + ".service"
            appliance.wait_until_succeeds("systemctl is-active --quiet " + unit, timeout=600)
            appliance.wait_until_succeeds(
              "nixos-container run " + q(settings["containerName"]) +
              " -- systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=600
            )
            appliance.wait_until_succeeds(
              "nixos-container run " + q(settings["containerName"]) +
              " -- systemctl is-active --quiet nix-daemon-custom.service", timeout=600
            )
            required = appliance.succeed("systemctl show " + unit + " -p Requires --value")
            assert "nixtache-overlay-ready.target" in required.split()
            parent = "host" if settings["parent"] is None else settings["parent"]
            frozen = EXPECTED_GRAPH["frozenLowerByLogical"][parent]
            assert "nixtache-overlay-frozen-" + frozen + ".service" in required.split()
            options = crun(node, "findmnt -n -o OPTIONS " + q(settings["path"] + "/nix/store"))
            assert "lowerdir=" + settings["lowerRoot"] + "/nix/store" in options, options
            upper = appliance.succeed("readlink -f " + q(runtime_upper(node))).strip()
            expected_upper = selected + "/nodes/" + EXPECTED_GRAPH["consumerNodeByLogical"][node] + "/upper"
            assert upper == expected_upper, f"{node} upper {upper} does not select {expected_upper}"
            appliance.succeed("test -f " + q(settings["lowerRoot"] + "/nix/var/nix/db/db.sqlite"))
        print("OK: production containers, daemon lowers and one atomic readiness boundary are active")

    def stage(version):
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp " + SYSUPDATE_PACKAGES[version] + "/* /var/lib/nixtache/ab-stage/abtest/"
        )
        appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
        appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_" + version, timeout=900)
        appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_" + version + "+*.efi", timeout=300)
        slot = inactive_slot()
        assert slot
        print("OK: real OTA installed version " + version + " into inactive slot " + slot)
        return slot

    def prepare(version, slot):
        appliance.succeed("systemctl reset-failed nixtache-overlay-prepare.service || true")
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=3600)
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == slot
        generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        target = "/var/lib/nix-overlay/upper-slots/" + slot + "/generations/" + generation
        appliance.succeed("grep -q '^image_version=" + version + "$' " + q(target + "/metadata"))
        assert appliance.succeed(
          "readlink -f /var/lib/nix-overlay/upper-slots/" + slot + "/current"
        ).strip() == target
        assert_plan(target)
        return target
  '';
in
{
  inherit lib pkgs otaLib oracle cachePub mkAppliance deployerNode;
  inherit markerPackages consumerPackages packagePaths pythonRunners pythonHelpers;
}

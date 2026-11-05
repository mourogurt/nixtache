# auto-update-vm — runNixOSTest behavioral contracts for the auto-update module
# (spec 09; TEST-SPECS-AUTO-UPDATE.md sec. 4): AU-F1...F4 (flake path) and
# AU-A1...A5 (ab path). AU-F5 (kernel-change reboot) stays a manual runbook —
# see the comment block at the bottom of this file.
#
# KVM: runNixOSTest carries
# requiredSystemFeatures = [ "kvm" "nixos-test" ] itself (as ab-deploy-self-vm).
#
# Flake-path fixture: a self-contained flake (nixpkgs by store path — no
# network) whose nixosConfigurations.autest toplevel adds hello. The same
# toplevel is built host-side and seeded into the VM store via
# virtualisation.additionalPaths, so the in-VM `nix build` resolves entirely
# from the local store. The fixture config carries test-instrumentation.nix so
# the test-driver backdoor unit survives the switch-to-configuration.
#
# Deviation from the test-spec fixture sketch (sec. 0.3/sec. 4.1): the spec asks for a
# bare git repo with v1/v2 commits and the VM built FROM v1. A runNixOSTest
# node cannot be bit-identical to a flake-built v1 (the test harness injects
# qemu-vm/test-instrumentation modules), so the repo holds the v2 config only;
# "unchanged source" (AU-F2/F3) is exercised by re-running the service without
# modifying the repo. All spec assertions are preserved.
{ nixpkgs
, self
, system ? "x86_64-linux"
, scenario ? "full"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  treeFixture = import ./overlay-tree-vm-lib.nix {
    inherit nixpkgs self system appliancePkgs;
    topology = "composed";
    upperOnUpdate = "reconcile";
  };
  treeDependencyPaths = with treeFixture.fixturePaths; [
    hostDependency
    sharedDependency
    leafDependency
    commonDependency
  ];
  treeTopologyDependencies = builtins.filter
    (package: builtins.elem package.outPath treeDependencyPaths)
    treeFixture.deployerDependencies;
  treeCacheDependencies = builtins.filter
    (package: package.outPath != treeFixture.v2SysupdatePkg.outPath)
    treeFixture.deployerDependencies;

  autoMod = self.nixosModules.auto-update;

  # -- flake-path fixture ----------------------------------------------------
  hostName = "autest";

  # Per-node self-contained flake (nixpkgs by store path — no network) whose
  # nixosConfigurations.autest toplevel = THE NODE'S OWN CONFIG + hello. The
  # config imports the same harness modules the test driver injects
  # (qemu-vm / test-instrumentation / guest-networking) so the activated
  # system's unit set matches the running one — switch-to-configuration then
  # leaves the test-driver backdoor, the store mounts and the running
  # nixtache units untouched, and only adds hello. criticalUnits differ per
  # node, so each node gets its own fixture (identical apply/auto-update unit
  # texts on both sides of the switch is what keeps the running oneshots
  # alive). The toplevel is also built host-side and seeded into the VM store
  # via virtualisation.additionalPaths, keeping the in-VM `nix build` a pure
  # local substitution.
  mkFlakeFixture = { criticalUnits, healthCheckTimeout ? 60, extraPackages ? [ "hello" ] }:
    let
      configFile = pkgs.writeText "configuration.nix" ''
        { pkgs, lib, ... }: {
          imports = [
            ${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix
            ${nixpkgs}/nixos/modules/testing/test-instrumentation.nix
            ${nixpkgs}/nixos/modules/virtualisation/guest-networking-options.nix
          ];
          nixpkgs.hostPlatform = "${system}";
          system.stateVersion = lib.trivial.release;
          networking.hostName = "${hostName}";
          documentation.nixos.enable = false;
          # Never boots — and its activation must not attempt a bootloader
          # install on switch (qemu-vm enables grub by default).
          boot.loader.grub.enable = false;
          # Constant version metadata (like nixos-test-base): the in-VM flake
          # eval and the host-side toplevel must produce the SAME derivation,
          # but a store-path nixpkgs input has no git revision → without this
          # the two evals get different versionSuffixes.
          system.nixos = {
            revision = lib.mkForce "constant-nixos-revision";
            versionSuffix = lib.mkForce "test";
            label = lib.mkForce "test";
          };
          # The fixture toplevel never boots; drop base bootability assertions
          # (root fileSystems, boot loader) so it builds standalone.
          assertions = lib.mkForce [ ];
          users.groups.nixtache-deploy = { };
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          services.nixtache.deploy-target = {
            enable = true;
            criticalUnits = [ ${lib.concatStringsSep " " (map (u: ''"${u}"'') criticalUnits)} ];
            healthCheckTimeout = ${toString healthCheckTimeout};
          };
          services.nixtache.auto-update = {
            enable = true;
            flake.url = "/srv/test-flake";
          };
          environment.systemPackages = with pkgs; [ ${lib.concatStringsSep " " extraPackages} ];
        }
      '';
      # The nixtache modules are flake=false inputs: pure-eval flakes may only
      # import paths reachable through declared inputs (a bare absolute store
      # path in `imports` is rejected inside the VM's `nix build`).
      flakeFile = pkgs.writeText "flake.nix" ''
        {
          inputs = {
            nixpkgs.url = "path:${nixpkgs}";
            deploy-target-mod = { url = "path:${../modules/deploy-target}"; flake = false; };
            auto-update-mod = { url = "path:${../modules/auto-update}"; flake = false; };
          };
          outputs = { nixpkgs, deploy-target-mod, auto-update-mod, ... }: {
            nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
              system = "${system}";
              # flake=false inputs are sourceInfo attrsets; string-coercion to
              # their outPath yields an importable module directory.
              modules = [
                (import "''${deploy-target-mod}")
                (import "''${auto-update-mod}")
                ./configuration.nix
              ];
            };
          };
        }
      '';
    in
    {
      repo = pkgs.runCommand "auto-update-test-flake" { } ''
        mkdir $out
        cp ${flakeFile} $out/flake.nix
        cp ${configFile} $out/configuration.nix
      '';
      toplevel =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ../modules/deploy-target ../modules/auto-update (import configFile) ];
        }).config.system.build.toplevel;
    };

  fixtureTarget = mkFlakeFixture { criticalUnits = [ "multi-user.target" ]; };
  # v3: a NEWER source than v2 — AU-F3 needs built ≠ current while a CI
  # pointer exists, otherwise the unchanged-check (spec sec. 5 runs it before the
  # pending-check) no-ops first and the skip branch is unreachable.
  fixtureTargetV3 = mkFlakeFixture {
    criticalUnits = [ "multi-user.target" ];
    extraPackages = [ "hello" "cowsay" ];
  };
  fixtureTargetFail = mkFlakeFixture {
    criticalUnits = [ "nonexistent.service" ];
    healthCheckTimeout = 30;
  };

  flakeNode = { criticalUnits, healthCheckTimeout ? 60, fixture, extraPaths ? [ ] }: { ... }: {
    imports = [ self.nixosModules.deploy-target autoMod ];
    networking.hostName = hostName;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    virtualisation.diskSize = 8192;
    virtualisation.memorySize = 2048;
    virtualisation.additionalPaths = [ fixture.toplevel nixpkgs.outPath ] ++ extraPaths;
    services.nixtache.deploy-target = {
      enable = true;
      inherit criticalUnits healthCheckTimeout;
      # The VM's store filesystem is a fraction of its 8 GiB disk — below the
      # 5 GiB default; lower the activation guard to fit (guard behavior is
      # covered by the stubbed-df module test in tests/deploy-target.nix).
      minFreeBytes = 256 * 1024 * 1024;
    };
    services.nixtache.auto-update = {
      enable = true;
      flake.url = "/srv/test-flake";
    };
  };

  # -- ab-path fixture (B1-style: local staging, provision on /dev/vdb) ------
  v2SysupdatePkg =
    (fixture.mkAppliance {
      version = "2";
      signVerify = false;
      dataPartition = false;
      stagingPath = "/var/lib/nixtache/ab-stage/abtest";
      storeSize = "512M";
      extraPackages = [ pkgs.hello ];
    }).config.system.build.sysupdate-package;

  pkgs_1 = pkgs.runCommand "auto-update-runtime" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';
  pkgs_2 = pkgs.runCommand "auto-update-tool" { } ''
    mkdir -p $out/bin
    printf '#!%s/bin/busybox sh\necho auto-update-tool-ok\n' "${pkgs_1}" > $out/bin/tool
    chmod +x $out/bin/tool
  '';
  pkgs_4 = pkgs.runCommand "auto-update-window-marker" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';
  p1Path = pkgs_1.outPath;
  p2Path = pkgs_2.outPath;
  p4Path = pkgs_4.outPath;

  mkAutoAppliance = { version, rebootPolicy, extraPackages ? [ ], withTreeDependencies ? false }:
    otaLib.mkAppliance {
      inherit version;
      storeSize = "1G";
      extraPackages = extraPackages;
      extraModules = [
        autoMod
        self.nixosModules.overlay-nix
        treeFixture.runtimeModule
        { system.extraDependencies = lib.optionals withTreeDependencies treeTopologyDependencies; }
        ({ lib, ... }: {
          networking.hosts = lib.mkForce { "192.168.1.7" = [ "deployer" ]; };
          services.nixtache.overlay-nix = {
            enable = true;
            upperOnUpdate = "reconcile";
          };
          services.nixtache.auto-update = {
            enable = true;
            inherit rebootPolicy;
            rebootWindow = lib.mkIf (rebootPolicy == "window") {
              start = "00:00";
              end = "23:59";
            };
          };
        })
      ];
    };

  v1Auto = mkAutoAppliance { version = "1"; rebootPolicy = "window"; extraPackages = [ pkgs_1 ]; withTreeDependencies = true; };
  v1AutoImage = "${v1Auto.config.system.build.image}/abtest_1.raw";
  v2Auto = mkAutoAppliance { version = "2"; rebootPolicy = "if-needed"; };
  v2AutoPkg = v2Auto.config.system.build.sysupdate-package;
  v3Auto = mkAutoAppliance { version = "3"; rebootPolicy = "never"; };
  v3AutoPkg = v3Auto.config.system.build.sysupdate-package;

  mkRegressionAppliance = { version, ephemeral ? false, extraPackages ? [ ] }:
    otaLib.mkAppliance {
      inherit version extraPackages;
      storeSize = "1G";
      extraModules = [
        autoMod
        self.nixosModules.overlay-nix
        ({ lib, ... }: {
          services.nixtache.overlay-nix = {
            enable = true;
            upperOnUpdate = "reconcile";
          } // lib.optionalAttrs ephemeral {
            upperDir = "/tmp/nix-overlay/upper";
            workDir = "/tmp/nix-overlay/work";
          };
          services.nixtache.auto-update = {
            enable = true;
            rebootPolicy = "window";
            rebootWindow = {
              start = "00:00";
              end = "23:59";
            };
          };
          fileSystems."/tmp/nix-overlay" = lib.mkIf ephemeral {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=755" ];
          };
        })
      ];
    };

  managedTmpfsV1 = mkRegressionAppliance {
    version = "1";
    ephemeral = true;
    extraPackages = [ pkgs_1 ];
  };
  managedTmpfsV1Image = "${managedTmpfsV1.config.system.build.image}/abtest_1.raw";
  managedTmpfsV2 = mkRegressionAppliance {
    version = "2";
    ephemeral = true;
    extraPackages = [ pkgs.hello ];
  };
  managedTmpfsV2Pkg = managedTmpfsV2.config.system.build.sysupdate-package;

  stackedV1 = mkRegressionAppliance { version = "1"; };
  stackedV1Image = "${stackedV1.config.system.build.image}/abtest_1.raw";
  stackedV2 = mkRegressionAppliance { version = "2"; };
  stackedV2Pkg = stackedV2.config.system.build.sysupdate-package;
  stackedV3 = mkRegressionAppliance { version = "3"; };
  stackedV3Pkg = stackedV3.config.system.build.sysupdate-package;
  stackedV3Rewritten = mkRegressionAppliance { version = "3"; extraPackages = [ pkgs_1 ]; };
  stackedV3RewrittenPkg = stackedV3Rewritten.config.system.build.sysupdate-package;

  stageDir = "/var/lib/nixtache/ab-stage/abtest";
  slotsDir = "/var/lib/nixtache/ab-slots";

  abCommon = { pkgs, ... }: {
    imports = [ self.nixosModules.deploy-target autoMod ];
    boot.loader.systemd-boot.bootCounting.enable = true;
    virtualisation.emptyDiskImages = [ 2048 ];
    services.nixtache.deploy-target = {
      enable = true;
      ab.enable = true;
      ab.partitions = {
        enable = true;
        slotSize = "512M";
        autoInit = true;
        imageId = "abtest";
        source = stageDir; # local path → regular-file transfers
        bootTarget = "${slotsDir}/"; # no ESP on this VM
        slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
        slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
      };
    };
    services.nixtache.auto-update.enable = true;
    systemd.tmpfiles.rules = [
      "d ${stageDir} 0755 root root -"
      "d ${slotsDir} 0755 root root -"
    ];
    system.extraDependencies = [ v2SysupdatePkg ];
    environment.systemPackages = with pkgs; [ gptfdisk util-linux squashfsTools ];
  };

  # Mock Forgejo API for the gating node (same pattern as ab-deploy-self-vm).
  mockApi = { ... }: {
    services.nginx.enable = true;
    services.nginx.virtualHosts."forgejo-mock" = {
      listen = [
        { addr = "127.0.0.1"; port = 8080; }
        { addr = "[::1]"; port = 8080; }
      ];
      locations."/api/v1/actions/runners" = {
        return = ''200 '[]' '';
        extraConfig = "default_type application/json;";
      };
    };
  };
in
assert lib.assertMsg (builtins.elem scenario [ "full" "managed-tmpfs-window" "no-intermediate-reboot" ])
  "unknown auto-update VM scenario: ${scenario}";
if scenario == "managed-tmpfs-window" then
  pkgs.testers.runNixOSTest {
    name = "auto-update-managed-tmpfs-window";
    globalTimeout = 5400;

    nodes.deployer = otaLib.deployerNode {
      extraDependencies = [ pkgs_2 managedTmpfsV2Pkg ];
    };

    testScript = ''
      def create_auto_machine(**kwargs):
          machine = create_machine(start_command="${otaLib.startCommand { image = managedTmpfsV1Image; }}", **kwargs)
          driver.machines_qemu.append(machine)
          return machine

      def stage(package):
          deployer.succeed(
            "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
            "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
            "cp " + package + "/* /var/lib/nixtache/ab-stage/abtest/"
          )

      def wait_fresh_boot(previous_id):
          appliance.connected = False
          appliance.wait_until_succeeds(
            "test \"$(cat /proc/sys/kernel/random/boot_id)\" != " + previous_id,
            timeout=1800,
          )
          appliance.wait_for_unit("multi-user.target", timeout=1800)

      def assert_no_persistent_proof():
          copies = appliance.succeed(
            "find /var/lib/nix-overlay /tmp/nix-overlay/upper-slots /tmp/nix-overlay/legacy-backup -name '${baseNameOf p2Path}' -print 2>/dev/null || true"
          ).strip()
          assert copies == "", f"ephemeral upper proof acquired persistent copies: {copies}"

      deployer.start()
      deployer.wait_for_unit("nginx.service")
      deployer.wait_for_unit("nix-serve.service")
      deployer.succeed(
        "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
      )

      appliance = create_auto_machine(name="appliance")
      appliance.start(allow_reboot=True)
      appliance.wait_for_unit("multi-user.target", timeout=1800)
      appliance.wait_until_succeeds("systemctl is-active --quiet boot-complete.target", timeout=300)
      appliance.wait_until_succeeds("nix --version", timeout=300)
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      appliance.succeed("test ! -e /run/nixtache-overlay/selected-slot")
      appliance.succeed("test ! -e /tmp/nix-overlay/upper-slots")

      appliance.succeed("nix-store --realize ${p2Path}", timeout=600)
      appliance.succeed("ln -sfn ${p2Path} /nix/var/nix/gcroots/managed-tmpfs-proof")
      appliance.succeed("${p2Path}/bin/tool")
      appliance.succeed("test -d /tmp/nix-overlay/upper/${baseNameOf p2Path}")
      for directory in [
        "/tmp/nix-overlay/upper",
        "/nix/var/nix/db",
        "/nix/var/nix/gcroots",
        "/nix/var/nix/profiles",
        "/nix/var/nix/temproots",
      ]:
          appliance.succeed(f"mkdir -p {directory} && touch {directory}/ephemeral-sentinel")

      original_boot = appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip()
      stage("${managedTmpfsV2Pkg}")
      appliance.succeed("systemctl start nixtache-auto-update.service", timeout=900)
      appliance.succeed("${otaLib.assertSysupdateInstalled}")
      appliance.succeed("sgdisk -p /dev/vda | grep nix-store_2")
      appliance.succeed("test -f /boot/EFI/Linux/abtest_2+*.efi")
      appliance.succeed("test -f /var/lib/nixtache/reboot-pending")
      assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == original_boot, "window policy rebooted during installation"
      assert_no_persistent_proof()
      print("OK: managed tmpfs OTA installed and recorded a deferred reboot without a persistent metaslot")

      appliance.succeed("systemctl start --no-block nixtache-auto-update-reboot.service", timeout=300)
      wait_fresh_boot(original_boot)
      assert appliance.succeed("cat /etc/image-version").strip() == "2"
      appliance.wait_until_succeeds("nix --version", timeout=300)
      appliance.wait_until_succeeds(
        "systemctl is-active --quiet nixtache-lower-store-db-load.service", timeout=180
      )
      for directory in [
        "/tmp/nix-overlay/upper",
        "/nix/var/nix/db",
        "/nix/var/nix/gcroots",
        "/nix/var/nix/profiles",
        "/nix/var/nix/temproots",
      ]:
          appliance.fail(f"test -e {directory}/ephemeral-sentinel")
      appliance.fail("test -e /tmp/nix-overlay/upper/${baseNameOf p2Path}")
      appliance.fail("test -e /nix/var/nix/gcroots/managed-tmpfs-proof || test -L /nix/var/nix/gcroots/managed-tmpfs-proof")
      appliance.fail("nix path-info ${p2Path}")
      appliance.succeed("nix path-info ${pkgs.hello}")
      marker = appliance.succeed("cat /tmp/nix-overlay/lower-state/lower-db-sha256").strip()
      expected_marker = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_2.lower-db | awk '{print $1}'").strip()
      assert marker == expected_marker, "tmpfs reboot did not load exactly the v2 lower DB dump"
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending")
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending-overlay")
      assert_no_persistent_proof()
      copies = appliance.succeed(
        "find /tmp/nix-overlay -name '${baseNameOf p2Path}' -print 2>/dev/null || true"
      ).strip()
      assert copies == "", f"ephemeral upper proof survived reboot in a managed copy: {copies}"
      print("PASS: managed tmpfs auto-update installed v2, deferred reboot, reset upper and DB, and loaded the v2 lower dump")
    '';
  }
else if scenario == "no-intermediate-reboot" then
  pkgs.testers.runNixOSTest {
    name = "auto-update-no-intermediate-reboot";
    globalTimeout = 5400;

    nodes.deployer = otaLib.deployerNode {
      extraDependencies = [ stackedV2Pkg stackedV3Pkg stackedV3RewrittenPkg ];
    };

    testScript = ''
      def create_auto_machine(**kwargs):
          machine = create_machine(start_command="${otaLib.startCommand { image = stackedV1Image; }}", **kwargs)
          driver.machines_qemu.append(machine)
          return machine

      def stage(package):
          deployer.succeed(
            "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
            "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
            "cp " + package + "/* /var/lib/nixtache/ab-stage/abtest/"
          )

      def install(package, version):
          stage(package)
          appliance.succeed("systemctl start nixtache-auto-update.service", timeout=900)
          appliance.succeed("${otaLib.assertSysupdateInstalled}")
          appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_" + version, timeout=300)
          appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_" + version + "+*.efi", timeout=300)

      def prepared_target():
          slot = appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip()
          generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
          target = f"/var/lib/nix-overlay/upper-slots/{slot}/generations/{generation}"
          return slot, generation, target

      def metadata_value(target, key):
          return appliance.succeed(f"sed -n 's/^{key}=//p' {target}/metadata").strip()

      def wait_fresh_boot(previous_id):
          appliance.connected = False
          appliance.wait_until_succeeds(
            "test \"$(cat /proc/sys/kernel/random/boot_id)\" != " + previous_id,
            timeout=1800,
          )
          appliance.wait_for_unit("multi-user.target", timeout=1800)

      deployer.start()
      deployer.wait_for_unit("nginx.service")
      appliance = create_auto_machine(name="appliance")
      appliance.start(allow_reboot=True)
      appliance.wait_for_unit("multi-user.target", timeout=1800)
      appliance.wait_until_succeeds("systemctl is-active --quiet boot-complete.target", timeout=300)
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      original_boot = appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip()

      install("${stackedV2Pkg}", "2")
      slot_v2, generation_v2, target_v2 = prepared_target()
      assert metadata_value(target_v2, "image_version") == "2"
      assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == original_boot, "v2 installation rebooted before v3 was installed"
      appliance.succeed("test -f /var/lib/nixtache/reboot-pending")

      appliance.succeed("test -f /var/lib/nixtache/reboot-pending-overlay")
      stage("${stackedV3Pkg}")
      appliance.succeed(
        "mkdir -p /etc/systemd/system/nixtache-overlay-prepare.service.d && "
        "echo '[Service]' > /etc/systemd/system/nixtache-overlay-prepare.service.d/fail.conf && "
        "echo 'ExecStartPre=/run/current-system/sw/bin/false' >> /etc/systemd/system/nixtache-overlay-prepare.service.d/fail.conf && "
        "systemctl daemon-reload"
      )
      appliance.fail("systemctl start nixtache-auto-update.service", timeout=900)
      appliance.succeed("${otaLib.assertSysupdateInstalled}")
      failed_v3_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_3.lower-db | cut -d ' ' -f 1").strip()
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending")
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending-overlay")
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending-overlay.tmp")
      assert prepared_target() == (slot_v2, generation_v2, target_v2), "failed v3 preparation replaced the ready v2 target"
      appliance.succeed("systemctl start nixtache-auto-update-reboot.service", timeout=300)
      assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == original_boot, "stale v2 markers rebooted after v3 preparation failed"
      print("OK: failed consecutive preparation invalidated the v2 deferred reboot markers")

      appliance.succeed(
        "rm -rf /etc/systemd/system/nixtache-overlay-prepare.service.d && systemctl daemon-reload"
      )
      install("${stackedV3RewrittenPkg}", "3")
      slot_v3, generation_v3, target_v3 = prepared_target()
      assert generation_v3 != generation_v2, "v3 installation reused the v2 preparation generation"
      assert metadata_value(target_v3, "state") == "ready"
      assert metadata_value(target_v3, "image_version") == "3", "pre-reboot metadata does not describe the installed v3 image"
      expected_v3_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_3.lower-db | cut -d ' ' -f 1").strip()
      assert expected_v3_sha != failed_v3_sha, "same-version rewrite did not change the lower DB checksum"
      assert metadata_value(target_v3, "lower_sha256") == expected_v3_sha, "pre-reboot metadata does not match the rewritten v3 lower DB dump"
      appliance.succeed("test -f /var/lib/nixtache/reboot-pending")
      appliance.succeed("test -f /var/lib/nixtache/reboot-pending-overlay")
      assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == original_boot, "an intermediate reboot occurred before the v3 assertions"
      print("OK: v1 -> v2 -> rewritten v3 without reboot produced a fresh ready v3 generation and matching lower SHA")

      appliance.succeed("systemctl start --no-block nixtache-auto-update-reboot.service", timeout=300)
      wait_fresh_boot(original_boot)
      assert appliance.succeed("cat /etc/image-version").strip() == "3"
      assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == slot_v3
      assert appliance.succeed("cat /run/nixtache-overlay/selected-generation").strip() == generation_v3, "boot recovery replaced the prepared v3 generation"
      assert appliance.succeed("readlink -f /var/lib/nix-overlay/upper-slots/" + slot_v3 + "/current").strip() == target_v3
      assert metadata_value(target_v3, "image_version") == "3"
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending")
      appliance.succeed("test ! -f /var/lib/nixtache/reboot-pending-overlay")
      print("PASS: stacked auto-update installs selected the exact pre-reboot v3 generation")
    '';
  }
else
pkgs.testers.runNixOSTest {
  name = "auto-update-vm";

  nodes = {
    deployer = otaLib.deployerNode {
      extraDependencies = [ pkgs_1 pkgs_2 pkgs_4 v2AutoPkg v3AutoPkg ] ++ treeCacheDependencies;
    };

    # AU-F1...F3: flake path, healthy probe.
    target = flakeNode {
      criticalUnits = [ "multi-user.target" ];
      fixture = fixtureTarget;
      extraPaths = [ fixtureTargetV3.toplevel ];
    };

    # AU-F4: probe guaranteed to fail → Tier-1 rollback through the timer path.
    targetfail = flakeNode {
      criticalUnits = [ "nonexistent.service" ];
      healthCheckTimeout = 30;
      fixture = fixtureTargetFail;
    };

    # AU-A1 + AU-A5: ab path, local staging, idempotent rerun.
    a = { ... }: { imports = [ abCommon ]; };

    # AU-A2: no newer image staged; rebootPolicy=if-needed must still not reboot.
    abidle = { ... }: {
      imports = [ abCommon ];
      services.nixtache.auto-update.rebootPolicy = "if-needed";
    };

    abreboot = { ... }: {
      imports = [ abCommon ];
      services.nixtache.auto-update.rebootPolicy = "if-needed";
    };

    abwindow = { ... }: {
      imports = [ abCommon ];
      services.nixtache.auto-update.rebootPolicy = "window";
    };

    # AU-A3: gating host → auto-update is a ci-driven no-op (ab.poll derived false).
    abgating = { pkgs, ... }: {
      imports = [ abCommon mockApi ];
      services.nixtache.deploy-target.ab = {
        gating = true;
        forgejoPort = 8080;
        forgejoApiTokenFile = pkgs.writeText "forgejo-token" "test-token";
        idleWaitTimeout = 20;
      };
      services.nixtache.auto-update.rebootPolicy = "never"; # A6
    };

    # AU-A4: signed staging (Verify=yes) accepted through the timer trigger.
    absigned = { pkgs, ... }: {
      imports = [ abCommon ];
      services.nixtache.deploy-target.ab.partitions.publicKeyFile =
        "${fixture.testSignKey}/pubring.pgp";
      environment.etc."nixtache-signing-key".source = "${fixture.testSignKey}/priv.asc";
      environment.systemPackages = [ pkgs.gnupg ];
    };
  };

  testScript = ''
    def boot_ts(node):
        return node.succeed("systemctl show -p ActiveEnterTimestamp multi-user.target").strip()

    # -- AU-F1: flake timer → apply unit activates the new toplevel ----------
    # A qemu-vm test node has no /nix/var/nix/profiles/system generation (it
    # boots the toplevel directly), so the switch is tracked via
    # /run/current-system (updated by every activation).
    target.start()
    target.wait_for_unit("multi-user.target")
    orig_system = target.succeed("readlink -f /run/current-system").strip()
    target.succeed("cp -r ${fixtureTarget.repo} /srv/test-flake && chmod -R u+w /srv/test-flake")
    target.fail("hello")
    target.succeed("systemctl start nixtache-auto-update.service", timeout=600)
    target.succeed("test ! -f /var/lib/nixtache/pending-system")  # consumed by apply
    target.succeed("hello")                                       # new toplevel active
    target.succeed("test \"$(readlink -f /run/current-system)\" = '${fixtureTarget.toplevel}'")
    target.succeed("journalctl -u nixtache-apply --no-pager | grep activated")
    target.succeed("journalctl -u nixtache-auto-update --no-pager | grep 'nixtache-auto-update:'")
    print("AU-F1 OK: flake pull → pointer → apply-unit activation (probe passed)")

    # -- AU-F2: unchanged flake → idempotent no-op ---------------------------
    def apply_activations():
        return int(target.succeed("journalctl -u nixtache-apply --no-pager | grep -c activated").strip())
    runs_before = apply_activations()
    target.succeed("systemctl start nixtache-auto-update.service", timeout=600)
    target.succeed("test ! -f /var/lib/nixtache/pending-system")
    target.succeed("journalctl -u nixtache-auto-update --no-pager | grep 'already at'")
    assert apply_activations() == runs_before, "apply unit must not re-run on a no-op"
    print("AU-F2 OK: unchanged source is a no-op — no pointer, apply not re-run")

    # -- AU-F3: CI pointer present → auto-update skips, pointer intact -------
    # Move the source to v3 (built ≠ current, so the run reaches the pending
    # check) and plant a foreign pointer, as a CI deploy in flight would.
    target.succeed("rm -rf /srv/test-flake && cp -r ${fixtureTargetV3.repo} /srv/test-flake && chmod -R u+w /srv/test-flake")
    target.succeed("echo '${fixtureTargetV3.toplevel}' > /var/lib/nixtache/pending-system")
    target.succeed("systemctl start nixtache-auto-update.service", timeout=600)
    target.succeed("journalctl -u nixtache-auto-update --no-pager | grep -i skipping")
    target.succeed("grep -Fx '${fixtureTargetV3.toplevel}' /var/lib/nixtache/pending-system")
    assert apply_activations() == runs_before, "apply unit must not run while a CI deploy is pending"
    target.succeed("rm /var/lib/nixtache/pending-system")
    print("AU-F3 OK: CI deploy pending → skip, foreign pointer untouched")
    target.shutdown()

    # -- AU-F4: apply probe fail → Tier-1 rollback, service exits non-zero ---
    # The profile-revert arm of nixtache-apply's rollback needs a previous
    # profile generation, which a qemu-vm boot never creates — so the
    # behavioral contract asserted here is: non-zero exit, the rollback marker
    # in the apply journal, and the pointer consumed by the rollback path.
    targetfail.start()
    targetfail.wait_for_unit("multi-user.target")
    targetfail.succeed("cp -r ${fixtureTargetFail.repo} /srv/test-flake && chmod -R u+w /srv/test-flake")
    targetfail.fail("systemctl start nixtache-auto-update.service", timeout=600)
    targetfail.succeed("journalctl -u nixtache-apply --no-pager | grep 'rolling back'")
    targetfail.succeed("test ! -f /var/lib/nixtache/pending-system")
    print("AU-F4 OK: broken criticalUnit → Tier-1 rollback through the timer path")
    targetfail.shutdown()

    # -- AU-A1: ab timer → sysupdate writes slot B ---------------------------
    a.start()
    a.wait_for_unit("nixtache-ab-provision.service")
    a.wait_for_unit("multi-user.target")
    a.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    a.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
    ts_before = boot_ts(a)
    a.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    a.wait_until_succeeds("test -f ${slotsDir}/abtest_2+*.efi", timeout=300)
    a.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
    a.succeed("${otaLib.assertSysupdateInstalled}")
    a.succeed("journalctl -u nixtache-auto-update --no-pager | grep 'nixtache-auto-update:'")
    assert boot_ts(a) == ts_before, "rebootPolicy default never — VM must not reboot"
    print("AU-A1 OK: auto-update triggered sysupdate — nix-store_2 + abtest_2+*.efi, no reboot")

    # -- AU-A5: rerun with unchanged staging → idempotent, single slot B -----
    a.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    a.wait_until_succeeds("test -f ${slotsDir}/abtest_2+*.efi", timeout=300)
    a.succeed("test \"$(sgdisk -p /dev/vdb | grep -c nix-store_2)\" -eq 1")
    a.succeed("sgdisk -p /dev/vdb | grep nix-store_1")  # rollback slot intact
    print("AU-A5 OK: repeat pull idempotent — exactly one nix-store_2, v1 slot kept")
    a.shutdown()

    # -- AU-A2: no newer image staged → exit 0, slots untouched, no reboot ---
    # (Spec stages "v2 already installed"; an empty staging dir on a fresh VM
    # is the same 'nothing newer' condition for sysupdate.)
    abidle.start()
    abidle.wait_for_unit("nixtache-ab-provision.service")
    abidle.wait_for_unit("multi-user.target")
    ts_before = boot_ts(abidle)
    abidle.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    abidle.fail("sgdisk -p /dev/vdb | grep nix-store_2")
    abidle.fail("test -f ${slotsDir}/abtest_2+*.efi")
    assert boot_ts(abidle) == ts_before, "no new image → no reboot even with rebootPolicy=if-needed"
    print("AU-A2 OK: nothing newer → clean no-op, if-needed did not reboot")
    abidle.shutdown()

    abreboot.start()
    abreboot.wait_for_unit("nixtache-ab-provision.service")
    abreboot.wait_for_unit("multi-user.target")
    abreboot.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
    ts_before = boot_ts(abreboot)
    abreboot.succeed("systemctl start --no-block nixtache-auto-update.service", timeout=300)
    try:
        abreboot.wait_until_succeeds("test -f ${slotsDir}/abtest_2+*.efi", timeout=300)
    except BrokenPipeError:
        pass
    abreboot.wait_for_shutdown()
    abreboot.start()
    abreboot.wait_for_unit("multi-user.target")
    assert boot_ts(abreboot) != ts_before, "completed install must produce a fresh boot"
    abreboot.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
    print("AU-A6 OK: completed install → if-needed rebooted into a fresh boot")
    abreboot.shutdown()

    abwindow.start()
    abwindow.wait_for_unit("nixtache-ab-provision.service")
    abwindow.wait_for_unit("multi-user.target")
    abwindow.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
    ts_before = boot_ts(abwindow)
    abwindow.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    abwindow.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
    abwindow.succeed("test -f /var/lib/nixtache/reboot-pending")
    assert boot_ts(abwindow) == ts_before, "window policy must defer the reboot"
    abwindow.succeed("${otaLib.assertSysupdateInstalled}")
    print("AU-A7 OK: completed install → window marker set, reboot deferred")

    abwindow.succeed("rm /var/lib/nixtache/reboot-pending")
    abwindow.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    abwindow.succeed("test ! -f /var/lib/nixtache/reboot-pending")
    assert boot_ts(abwindow) == ts_before, "no-op result must not reboot under window policy"
    print("AU-A8 OK: no new image → no window marker and no reboot")
    abwindow.shutdown()

    # -- AU-A3: gating host → ci-driven no-op, sysupdate untouched -----------
    abgating.start()
    abgating.wait_for_unit("nixtache-ab-provision.service")
    abgating.wait_for_unit("nginx.service")
    abgating.succeed("curl -sf http://localhost:8080/api/v1/actions/runners | grep -Fx '[]'")
    abgating.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
    abgating.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    abgating.succeed("journalctl -u nixtache-auto-update --no-pager | grep ci-driven")
    abgating.fail("sgdisk -p /dev/vdb | grep nix-store_2")
    abgating.fail("test -f ${slotsDir}/abtest_2+*.efi")
    abgating.succeed("test ! -f /var/lib/nixtache/ab-pending")  # CI's signal — not ours
    print("AU-A3 OK: gating host — ci-driven marker, sysupdate not triggered")
    abgating.shutdown()

    # -- AU-A4: signed staging (Verify=yes) accepted via the timer trigger ---
    absigned.start()
    absigned.wait_for_unit("nixtache-ab-provision.service")
    absigned.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
    absigned.succeed(
      "export GNUPGHOME=$(mktemp -d) && "
      "gpg --batch --import /etc/nixtache-signing-key 2>/dev/null && "
      "cd ${stageDir} && gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS"
    )
    absigned.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    absigned.wait_until_succeeds("test -f ${slotsDir}/abtest_2+*.efi", timeout=300)
    absigned.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
    absigned.succeed("${otaLib.assertSysupdateInstalled}")
    print("AU-A4 OK: signed image accepted through the auto-update trigger")
    absigned.shutdown()

    # -- AB + persistent overlay: prepare once and refresh a deferred source --
    def create_auto_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1AutoImage; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def stage_auto(package):
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp " + package + "/* /var/lib/nixtache/ab-stage/abtest/"
        )

    import shlex

    TREE_STORES = ${builtins.toJSON treeFixture.storeUrls}
    TREE_STATES = ${builtins.toJSON treeFixture.stateDirs}
    TREE_UPPERS = ${builtins.toJSON treeFixture.upperDirs}
    TREE_CONSUMERS = ${builtins.toJSON treeFixture.consumersByNode}
    TREE_EXTRA_ROOTS = ${builtins.toJSON treeFixture.extraRoots}

    def tree_nix_store(node, args):
        features = "ca-derivations local-overlay-store read-only-local-store"
        return "nix-store --option experimental-features " + shlex.quote(features) + " --store " + shlex.quote(TREE_STORES[node]) + " " + args

    def tree_realize(node, path):
        auto.succeed(tree_nix_store(node, "--realize " + shlex.quote(path)), timeout=600)

    def tree_add_root(node, path, name):
        root = TREE_STATES[node] + "/gcroots/" + name
        auto.succeed("mkdir -p " + shlex.quote(TREE_STATES[node] + "/gcroots") + " && ln -sfn " + shlex.quote(path) + " " + shlex.quote(root))

    def tree_seed_consumers():
        for node, path in TREE_CONSUMERS.items():
            tree_realize(node, path)
            tree_add_root(node, path, "overlay-tree-" + node)
        for root in TREE_EXTRA_ROOTS:
            tree_realize(root["node"], root["path"])
            tree_add_root(root["node"], root["path"], root["name"])

    def tree_add_deferred_marker():
        for node in reversed(${builtins.toJSON treeFixture.nodeIds}):
            tree_realize(node, "${p4Path}")
            tree_add_root(node, "${p4Path}", "deferred-window")

    def assert_tree_deferred_marker():
        basename = "${baseNameOf p4Path}"
        for node in TREE_STORES:
            auto.succeed("test -e " + shlex.quote(TREE_UPPERS[node] + "/" + basename))
            root = TREE_STATES[node] + "/gcroots/deferred-window"
            assert auto.succeed("readlink " + shlex.quote(root)).strip() == "${p4Path}"
        print("OK: deferred source refresh preserved the marker at host, intermediate, leaf and sibling")

    def preparation_count(node):
        return int(node.succeed(
          "journalctl -u nixtache-overlay-prepare.service --no-pager | "
          "grep -c 'Starting Prepare the inactive'"
        ).strip())

    def wait_fresh_boot(node, previous_id):
        node.connected = False
        node.wait_until_succeeds(
          "test \"$(cat /proc/sys/kernel/random/boot_id)\" != " + previous_id,
          timeout=1800,
        )
        node.wait_for_unit("multi-user.target")

    deployer.start()
    deployer.wait_for_unit("nginx.service")
    deployer.wait_for_unit("nix-serve.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )
    auto = create_auto_machine(name="auto")
    auto.start(allow_reboot=True)
    auto.wait_for_unit("multi-user.target")
    auto.wait_until_succeeds("nix --version", timeout=300)
    print("DIAG deployer addresses: " + deployer.succeed("ip -brief address"))
    print("DIAG auto addresses/routes: " + auto.succeed("ip -brief address; ip route"))
    auto.wait_until_succeeds("curl -sf http://deployer:5000/nix-cache-info", timeout=120)
    auto.succeed("nix-store --realize ${p2Path}", timeout=600)
    auto.succeed("ln -sfn ${p2Path} /nix/var/nix/gcroots/auto-update-tool")
    auto.succeed("${p2Path}/bin/tool")
    tree_seed_consumers()
    stage_auto("${v2AutoPkg}")
    auto.succeed("systemctl start nixtache-auto-update.service", timeout=900)
    auto.succeed("test -f /var/lib/nixtache/reboot-pending")
    auto.succeed("test -f /var/lib/nixtache/reboot-pending-overlay")
    assert preparation_count(auto) == 1, "window installation did not prepare exactly once"
    auto.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    assert preparation_count(auto) == 1, "no-op poll invoked upper preparation"
    deferred_target = auto.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
    tree_add_deferred_marker()
    deferred_boot = auto.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    auto.succeed("systemctl start --no-block nixtache-auto-update-reboot.service", timeout=300)
    wait_fresh_boot(auto, deferred_boot)
    assert auto.succeed("cat /etc/image-version").strip() == "2"
    assert preparation_count(auto) == 2, "changed deferred source did not refresh exactly once"
    auto.succeed("test ! -f /var/lib/nixtache/reboot-pending")
    auto.succeed("test ! -f /var/lib/nixtache/reboot-pending-overlay")
    auto.succeed("${p4Path}/bin/busybox echo deferred-source-present")
    auto.succeed("${p2Path}/bin/tool")
    current_deferred = auto.succeed(
      "basename \"$(readlink -f /var/lib/nix-overlay/upper-slots/$(cat /run/nixtache-overlay/selected-slot)/current)\""
    ).strip()
    assert current_deferred != deferred_target, "deferred refresh reused the installation-time target generation"
    assert_tree_deferred_marker()
    print("AU-OVERLAY-WINDOW OK: no-op skips preparation; changed active generation refreshes the deferred target")

    stage_auto("${v3AutoPkg}")
    before_immediate = preparation_count(auto)
    immediate_boot = auto.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    auto.succeed("systemctl start --no-block nixtache-auto-update.service", timeout=300)
    wait_fresh_boot(auto, immediate_boot)
    assert auto.succeed("cat /etc/image-version").strip() == "3"
    assert preparation_count(auto) == before_immediate + 1, "immediate update did not prepare exactly once"
    auto.succeed("${p4Path}/bin/busybox echo immediate-target-ready")
    auto.succeed("${p2Path}/bin/tool")
    assert_tree_deferred_marker()
    immediate_count = preparation_count(auto)
    after_immediate_boot = auto.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    deployer.succeed(
      "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
      ": > /var/lib/nixtache/ab-stage/abtest/SHA256SUMS"
    )
    auto.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    assert preparation_count(auto) == immediate_count, "immediate no-op poll invoked preparation"
    assert auto.succeed("cat /proc/sys/kernel/random/boot_id").strip() == after_immediate_boot
    print("AU-OVERLAY-IMMEDIATE OK: completed install prepares once and reboots; no-op neither prepares nor reboots")

    print("PASS: AU-F1..F4 (flake path) + AU-A1..A5 + overlay preparation/deferred refresh")
  '';
}

# -- AU-F5 (📋 manual): rebootPolicy = "if-needed" reboots on kernel change ---
# Flagged as an open question in the test-spec (sec. 9.1): flipping
# boot.kernelPackages between two full VM builds is too expensive for CI, and
# /run/booted-system is a boot-time symlink that cannot be re-pointed safely on
# a live system. The branch is covered pure-eval by AU-12A. Manual runbook:
#   1. Deploy a host with auto-update { enable = true; rebootPolicy =
#      "if-needed"; } and flake.url pointing at a config whose
#      boot.kernelPackages differs from the running kernel.
#   2. systemctl start nixtache-auto-update.service
#   3. Expect: apply succeeds, the script's kernel compare
#      (/run/booted-system vs /run/current-system) detects the change and the
#      machine reboots; after reboot `uname -r` matches the new toplevel's
#      kernel and the journal holds the auto-update markers.

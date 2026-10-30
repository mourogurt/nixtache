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
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };

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
pkgs.testers.runNixOSTest {
  name = "auto-update-vm";

  nodes = {
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
        return node.succeed("systemctl show -p ActiveEnterTimestamp multi-user.target")

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
    abreboot.succeed("systemctl start nixtache-auto-update.service", timeout=300)
    abreboot.wait_until_succeeds(
      f"test \"$(systemctl show -p ActiveEnterTimestamp multi-user.target)\" != '{ts_before}'",
      timeout=600
    )
    abreboot.wait_for_unit("multi-user.target")
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

    print("PASS: AU-F1..F4 (flake path) + AU-A1..A5 (ab path) behave per spec 09")
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

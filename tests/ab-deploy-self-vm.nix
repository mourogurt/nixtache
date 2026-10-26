# ab-deploy-self-vm — self-deploy + gating scenarios via runNixOSTest. Needs KVM (runNixOSTest carries
# requiredSystemFeatures = [ "kvm" "nixos-test" ] itself, like ab-provision-vm).
#
# Four independent 1-node scenarios. Every node is a plain NixOS VM (NOT the
# appliance) importing the REAL deploy-target module with
# `ab.partitions.source` pointing at a LOCAL staging dir — the provision module
# derives regular-file transfers (plain absolute path; sysupdate rejects
# file:// URIs for regular-file sources) for both the nix-store and the UKI
# transfer, and `nixtache-ab-provision.service` lays out the GPT on /dev/vdb at
# boot. The v2 sysupdate-package (built by the fixture's mkAppliance) is copied
# into the staging dir by the testScript; no SSH, no deployer node.
#
#   B1 ab-deploy-self:               direct `systemctl start systemd-sysupdate`
#   B2 ab-deploy-self-gating:        mock Forgejo API returns [] (all idle)
#                                    → nixtache-ab-apply applies
#   B3 ab-deploy-self-busy:          mock returns a busy runner,
#                                    forceAfterTimeout=false → stays pending
#   B4 ab-deploy-self-busy-timeout:  busy + forceAfterTimeout=true → forced apply
#
# The mock Forgejo API is an nginx vhost on 127.0.0.1/[::1]:8080 serving a
# static JSON body for /api/v1/actions/runners; the node points the NEW
# self-contained option `ab.forgejoPort` at it (no runner module import).
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

  # v2 — the update staged into the local staging dir. Only its
  # sysupdate-package output is used (abtest_2.nix-store.raw, abtest_2+*.efi,
  # SHA256SUMS — the manifest ships in the package, unsigned: these nodes set
  # no publicKeyFile, so the provision module derives Transfer.Verify=no).
  v2Config = fixture.mkAppliance {
    version = "2";
    signVerify = false;
    dataPartition = false;
    stagingPath = "/var/lib/nixtache/ab-stage/abtest";
    storeSize = "512M";
    extraPackages = [ pkgs.hello ];
  };
  v2SysupdatePkg = v2Config.config.system.build.sysupdate-package;

  stageDir = "/var/lib/nixtache/ab-stage/abtest";
  slotsDir = "/var/lib/nixtache/ab-slots";

  # Shared node config: provision module owns sysupdate + transfers + GPT
  # layout on /dev/vdb; staging + boot-target dirs exist via tmpfiles.
  common = { pkgs, ... }: {
    imports = [ self.nixosModules.deploy-target ];
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
    systemd.tmpfiles.rules = [
      "d ${stageDir} 0755 root root -"
      "d ${slotsDir} 0755 root root -"
    ];
    system.extraDependencies = [ v2SysupdatePkg ];
    environment.systemPackages = with pkgs; [ gptfdisk util-linux squashfsTools ];
  };

  # Mock Forgejo API: static JSON for /api/v1/actions/runners on port 8080.
  mockApi = runnersJson: { lib, ... }: {
    services.nginx.enable = true;
    services.nginx.virtualHosts."forgejo-mock" = {
      listen = [
        { addr = "127.0.0.1"; port = 8080; }
        { addr = "[::1]"; port = 8080; }
      ];
      locations."/api/v1/actions/runners" = {
        return = ''200 '${runnersJson}' '';
        extraConfig = "default_type application/json;";
      };
    };
  };

  gatingConfig = { lib, ... }: {
    services.nixtache.deploy-target.ab = {
      gating = true;
      forgejoPort = 8080;
      forgejoApiTokenFile = pkgs.writeText "forgejo-token" "test-token";
      idleWaitTimeout = 20;
    };
  };

  # Test-doubles for the two stock sysupdate units — this suite's subject is
  # the GATING logic, not sysupdate itself (slot mechanics are covered by B1
  # and the ab-ota-* suites): the plain update unit gets a wrapper that runs
  # the REAL update but can be forced to FAIL on demand (/run/sysupdate-fail)
  # to exercise the retry-safe pending-flag path, and the reboot unit becomes
  # a no-op so an apply never reboots the VM mid-gating-scenario. The gating
  # unit itself — its script, the --wait update → pending consumption →
  # reboot-assessment ordering — stays REAL.
  # (A systemd.units text override CONCATENATES with the package unit via
  # types.lines, and an ExecStart list with a "" reset renders a broken empty
  # line — a full service declaration is the working mechanism.)
  sysupdateWrapper = pkgs.writeShellScript "sysupdate-update-test" ''
    if [ -e /run/sysupdate-fail ]; then
      echo "test wrapper: forced failure (/run/sysupdate-fail present)" >&2
      exit 1
    fi
    exec ${pkgs.systemd}/lib/systemd/systemd-sysupdate update
  '';
  noReboot = {
    systemd.services.systemd-sysupdate = {
      description = "systemd-sysupdate update (TEST wrapper: fail-on-flag)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ "" "${sysupdateWrapper}" ];
      };
    };
    systemd.services."systemd-sysupdate-reboot" = {
      description = "systemd-sysupdate reboot (TEST no-op: gating scenarios must not reboot)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ "" "${pkgs.coreutils}/bin/true" ];
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "ab-deploy-self-vm";

  nodes = {
    # B1: direct sysupdate against the local staging (no gating).
    b1 = { ... }: {
      imports = [ common ];
      services.nixtache.deploy-target.ab.gating = false;
    };

    # B2: gating, all runners idle → apply proceeds.
    b2 = { ... }: {
      imports = [ common gatingConfig (mockApi "[]") noReboot ];
    };

    # B3: gating, runner busy, no force → pending kept, slot B untouched.
    b3 = { ... }: {
      imports = [ common gatingConfig (mockApi ''[{"name":"r1","busy":true}]'') noReboot ];
      services.nixtache.deploy-target.ab.forceAfterTimeout = false;
    };

    # B4: gating, runner busy, forceAfterTimeout=true → forced apply.
    b4 = { ... }: {
      imports = [ common gatingConfig (mockApi ''[{"name":"r1","busy":true}]'') noReboot ];
      services.nixtache.deploy-target.ab.forceAfterTimeout = true;
    };
  };

  testScript = ''
    def check_provisioned(node):
        node.wait_for_unit("nixtache-ab-provision.service")
        node.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
        node.succeed("sgdisk -p /dev/vdb | grep _empty")

    def stage_v2(node):
        node.succeed("cp ${v2SysupdatePkg}/* ${stageDir}/")
        node.succeed("test -f ${stageDir}/abtest_2.nix-store.raw")
        node.succeed("test -f ${stageDir}/abtest_2+*.efi")
        node.succeed("grep abtest_2 ${stageDir}/SHA256SUMS")

    # systemd-sysupdate.service is Type=simple upstream, so `systemctl start`
    # returns as soon as the process forks — the slot write finishes in the
    # background. Always wait for the .efi (the LAST transfer) before asserting.
    def check_slot_b_written(node):
        node.wait_until_succeeds("test -f ${slotsDir}/abtest_2+*.efi", timeout=300)
        node.succeed("sgdisk -p /dev/vdb | grep nix-store_2")

    # -- B1: local staging + direct sysupdate trigger ------------------------
    b1.start()
    check_provisioned(b1)
    stage_v2(b1)
    b1.succeed("systemctl start systemd-sysupdate.service", timeout=300)
    check_slot_b_written(b1)
    # Install evidence from the journal of THIS (installing) boot via the
    # shared helper — B1 never reboots, so the query cannot race a reboot.
    b1.succeed("${otaLib.assertSysupdateInstalled}")
    b1.succeed("unsquashfs -l /dev/vdb2 | grep hello")  # v2 content in slot B
    b1.succeed("sgdisk -p /dev/vdb | grep nix-store_1")  # rollback slot intact
    print("B1 OK: self-deploy wrote nix-store_2 + abtest_2+*.efi from local staging")
    b1.shutdown()

    # -- B2: gating, runners idle → apply ------------------------------------
    b2.start()
    check_provisioned(b2)
    b2.wait_for_unit("nginx.service")
    # the mock answers the exact probe the gating script issues
    b2.succeed("curl -sf http://localhost:8080/api/v1/actions/runners | grep -Fx '[]'")

    # Retry-safe gating (finalize): a FAILED sysupdate start must keep the
    # ab-pending flag so the next path-trigger retries — the signal is consumed
    # only after a successful start. The `touch` itself fires the systemd.path
    # trigger (that's the production activation path); the wrapper unit fails
    # against the /run/sysupdate-fail flag.
    b2.succeed("touch /run/sysupdate-fail")
    b2.succeed("touch /var/lib/nixtache/ab-pending")
    b2.wait_until_succeeds(
      "systemctl is-failed nixtache-ab-apply.service", timeout=60
    )
    b2.succeed("test -f /var/lib/nixtache/ab-pending")  # NOT consumed on failure
    b2.succeed("journalctl -u nixtache-ab-apply --no-pager | grep 'for retry'")
    b2.succeed("rm /run/sysupdate-fail")
    # Clear the intentional failures + rate-limit windows (BOTH the gating unit
    # and the sysupdate unit it failed to start) so the REAL apply below is not
    # blocked by start-limit-hit.
    b2.succeed("systemctl reset-failed nixtache-ab-apply.service systemd-sysupdate.service")
    print("B2 OK (pre): failed sysupdate start keeps ab-pending for retry")

    stage_v2(b2)
    b2.succeed("touch /var/lib/nixtache/ab-pending && systemctl start nixtache-ab-apply.service", timeout=300)
    check_slot_b_written(b2)
    b2.succeed("test ! -f /var/lib/nixtache/ab-pending")
    b2.succeed("journalctl -u nixtache-ab-apply --no-pager | grep 'runners idle'")
    # The gating script delegates to nixtache-ab-update.service (oneshot:
    # update to completion, reboot only on install evidence; the reboot unit
    # itself is no-op'd above). `systemctl cat` shows only the script wrapper
    # path — grep its text. The delegation target's own script must carry the
    # reboot assessment.
    b2.succeed(
      "f=$(systemctl show -p ExecStart --value nixtache-ab-apply.service); "
      + "grep nixtache-ab-update.service \"$(echo \"$f\" | sed -E 's/^\\{ path=([^ ;]+).*/\\1/')\""
    )
    b2.succeed(
      "f=$(systemctl show -p ExecStart --value nixtache-ab-update.service); "
      + "grep systemd-sysupdate-reboot.service \"$(echo \"$f\" | sed -E 's/^\\{ path=([^ ;]+).*/\\1/')\""
    )
    print("B2 OK: idle gate passed — sysupdate applied, pending cleared")
    b2.shutdown()

    # -- B3: gating, runner busy, forceAfterTimeout=false → stays pending ----
    b3.start()
    check_provisioned(b3)
    b3.wait_for_unit("nginx.service")
    b3.succeed("curl -sf http://localhost:8080/api/v1/actions/runners | grep busy")
    stage_v2(b3)
    b3.succeed("touch /var/lib/nixtache/ab-pending && systemctl start nixtache-ab-apply.service", timeout=300)
    b3.succeed("test -f /var/lib/nixtache/ab-pending")  # NOT cleared
    b3.fail("sgdisk -p /dev/vdb | grep nix-store_2")   # slot B NOT written
    b3.fail("test -f ${slotsDir}/abtest_2+*.efi")
    b3.succeed("journalctl -u nixtache-ab-apply --no-pager | grep 'still busy.*forceAfterTimeout=false'")
    print("B3 OK: busy + no force — apply deferred, pending kept, slot B untouched")
    b3.shutdown()

    # -- B4: gating, runner busy, forceAfterTimeout=true → forced apply ------
    b4.start()
    check_provisioned(b4)
    b4.wait_for_unit("nginx.service")
    stage_v2(b4)
    b4.succeed("touch /var/lib/nixtache/ab-pending && systemctl start nixtache-ab-apply.service", timeout=300)
    check_slot_b_written(b4)
    b4.succeed("test ! -f /var/lib/nixtache/ab-pending")
    b4.succeed("journalctl -u nixtache-ab-apply --no-pager | grep 'applying anyway'")
    print("B4 OK: busy + forceAfterTimeout=true — update applied after the idle window")
    b4.shutdown()

    print("PASS: B1-B4 — self-deploy (local staging) + idle/busy/forced gating all behave per spec")
  '';
}

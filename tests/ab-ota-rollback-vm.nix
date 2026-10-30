# ab-ota-rollback-vm — boot-counting ROLLBACK: a broken new image exhausts
# its tries and the previously blessed entry boots; the machine stays
# OTA-manageable (a fixed follow-up installs normally).
#
# Tier-0 semantics under test (modules/deploy-target/health-check.nix): a
# failing critical unit keeps boot-complete.target unreached, so the boot is
# never blessed; with boot counting on, each boot of the unblessed entry
# burns a try and, once exhausted, systemd-boot skips the entry and falls
# back to the last blessed one. The test drives the reboots (Tier-0 itself
# never reboots — it only withholds the blessing).
#
# Images: v1 plain (blessed first); v2 carries a canary unit that FAILS and
# is listed in criticalUnits (ukiTries=2, healthCheckTimeout=20s to keep the
# failure window short); v3 is the fixed follow-up (hello marker proves new
# lower content). Needs KVM. Hermetic (deployer LAN only).
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) fixture pkgs;

  # v2's broken boot: the canary fails, Tier-0 sees it via criticalUnits and
  # withholds the blessing. Short health window keeps each failed boot quick.
  brokenBootModules = [
    ({ lib, ... }: {
      services.nixtache.ab-image.ukiTries = 2;
      services.nixtache.deploy-target = {
        healthCheckTimeout = 20;
        criticalUnits = [ "nixtache-rollback-canary.service" ];
      };
      systemd.services.nixtache-rollback-canary = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          echo "nixtache-rollback-canary: failing on purpose (rollback test)"
          exit 1
        '';
      };
    })
  ];

  v1 = otaLib.mkAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = otaLib.mkAppliance { version = "2"; extraModules = brokenBootModules; };
  v2Pkg = v2.config.system.build.sysupdate-package;
  v3 = otaLib.mkAppliance { version = "3"; extraPackages = [ pkgs.hello ]; };
  v3Pkg = v3.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "ab-ota-rollback";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ v2Pkg v3Pkg ]; };

  testScript = ''
    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    deployer.start()
    deployer.wait_for_unit("nginx.service")

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    # v1 must be blessed first: a blessed entry outranks raw tries, so the
    # fallback target after v2's failure is a KNOWN-good boot.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("OK: v1 booted and blessed")

    # -- Install the broken v2 (tries=2) ------------------------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: broken v2 installed to slot B")

    # -- Burn both tries: boot v2 twice, each unblessed ---------------------
    for i in (1, 2):
        appliance.reboot()
        appliance.wait_for_unit("multi-user.target")
        version = appliance.succeed("cat /etc/image-version").strip()
        assert version == "2", f"boot {i}: expected v2 (tries burning), got {version}"
        # The health window (20s) lapses unblessed; the machine keeps running.
        appliance.wait_until_fails(
          "systemctl is-active --quiet nixtache-health-check.service", timeout=120
        )
        appliance.wait_until_succeeds(
          "journalctl -u nixtache-rollback-canary.service -b --no-pager | grep -q 'failing on purpose'",
          timeout=60
        )
        print(f"OK: v2 boot {i} unblessed (canary failed, no bless)")

    # -- Tries exhausted → the loader falls back to blessed v1 --------------
    # NOTE: the rolled-back v1 boot does NOT (re)reach boot-complete.target:
    # its entry was blessed on the first boot (the counter became the done
    # form), systemd-bless-boot therefore skips and does not pull the target
    # in. The rollback evidence is the booted version + the exhausted entry.
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "1", f"rollback failed: booted {version}, expected 1"
    # exhausted entries carry the left-done form (+0 or +0-N)
    appliance.succeed("ls /boot/EFI/Linux/abtest_2+0*.efi > /dev/null")
    appliance.succeed("systemctl is-active --quiet sshd.service")
    print("ROLLBACK OK: exhausted v2 (+0 tries left) skipped, blessed v1 boots")

    appliance.succeed("systemctl is-active --quiet sshd.service")
    appliance.succeed("systemctl is-active --quiet systemd-sysupdate.timer")
    appliance.succeed("systemd-sysupdate list > /dev/null")
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_1")
    running_hash = appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1")

    appliance.fail("nixtache-ab-recover 1")
    appliance.succeed(
      "cp /boot/EFI/Linux/abtest_2+0*.efi "
      "/boot/EFI/Linux/abtest_2+0-duplicate.efi"
    )
    appliance.fail("nixtache-ab-recover 2")
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_2")
    appliance.succeed("rm /boot/EFI/Linux/abtest_2+0-duplicate.efi")
    print("OK: recovery refuses the running version and ambiguous artifact deletion")

    appliance.succeed("nixtache-ab-recover 2")
    appliance.fail("sgdisk -p /dev/vda | grep nix-store_2")
    appliance.succeed("sgdisk -p /dev/vda | grep _empty")
    appliance.fail("ls /boot/EFI/Linux/abtest_2+*.efi > /dev/null")
    appliance.fail("ls /boot/EFI/nixtache/abtest_2.lower-db > /dev/null")
    assert appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1") == running_hash
    print("RECOVERY OK: failed v2 removed, inactive slot empty, running v1 preserved")

    deployer.succeed(
      "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
      "cp ${v3Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_3")
    appliance.succeed("test -f /boot/EFI/Linux/abtest_3+*.efi")
    assert appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1") == running_hash
    print("OK: fixed v3 installed only into the inactive slot")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "3"
    appliance.succeed("hello")
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("PASS: rollback → explicit recovery → fixed v3 boots and is blessed; running v1 was never overwritten")
  '';
}

# ab-ota-interrupted-vm — an update killed mid-transfer is recoverable: the
# active slot is never the write target, the half-written inactive slot is
# never booted (its boot entry lands only after the FULL transfer), and the
# next sysupdate run rewrites the inactive slot completely.
#
# Interruption window: sysupdate relabels the target partition BEFORE
# downloading the content (pinned by ab-ota-e2e), so killing right after the
# label appears always lands inside the download. Needs KVM. Hermetic.
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) pkgs;

  v1 = otaLib.mkAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = otaLib.mkAppliance { version = "2"; extraPackages = [ pkgs.hello ]; };
  v2Pkg = v2.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "ab-ota-interrupted";
  globalTimeout = 3600;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ v2Pkg ]; };

  testScript = ''
    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand v1Image}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    deployer.start()
    deployer.wait_for_unit("nginx.service")

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("OK: v1 booted and blessed")

    # -- Kill sysupdate inside the download window --------------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    # --no-block: the trigger returns immediately; the poll below watches for
    # the relabel (set before the content download), then SIGKILLs the unit.
    appliance.succeed("systemctl start --no-block systemd-sysupdate.service")
    appliance.wait_until_succeeds(
      "sgdisk -p /dev/vda | grep -q nix-store_2", timeout=300
    )
    appliance.succeed("systemctl kill -s SIGKILL systemd-sysupdate.service || true")
    appliance.wait_until_fails("systemctl is-active --quiet systemd-sysupdate.service", timeout=120)
    # The interruption is proven mid-transfer: the label changed but the boot
    # entry (the SECOND transfer) never landed.
    appliance.fail("test -f /boot/EFI/Linux/abtest_2+*.efi")
    print("OK: sysupdate killed mid-download (slot labelled, no boot entry)")

    # -- Reboot: the half-written slot is never chosen ----------------------
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "1", f"partial slot booted: got version {version}"
    print("OK: reboot after interruption still boots v1 (active slot untouched)")

    # -- The next run rewrites the inactive slot completely -----------------
    # sysupdate refuses a partially-installed version ("already acquired and
    # partially installed. Vacuum it") — vacuum removes the partial instance,
    # then the retry installs it in full.
    appliance.succeed("systemd-sysupdate vacuum", timeout=300)
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds(
      "test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=900
    )
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet systemd-sysupdate.service || "
      "test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=60
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "2", f"recovery run failed: booted {version}, expected 2"
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("PASS: interrupted update recovered; v2 installed and blessed")
  '';
}

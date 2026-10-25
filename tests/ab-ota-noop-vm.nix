# ab-ota-noop-vm — same-version staging is a no-op: re-running sysupdate
# with the already-installed version installs nothing (no slot write, no new
# boot entry), and the trigger completes green.
#
# The ACTION-level equivalent (deploying the same NIXTACHE_AB_VERSION twice)
# funnels into exactly this sysupdate behaviour — the action's staging + SSH
# trigger are covered by ab-ota-e2e; this suite pins the target-side no-op.
# Needs KVM. Hermetic (deployer LAN only).
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
  name = "ab-ota-noop";
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

    # -- First run: v2 installs to slot B -----------------------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: v2 installed to slot B")

    # -- Second run, same version: nothing changes --------------------------
    before_parts = appliance.succeed("sgdisk -p /dev/vda")
    before_efi = appliance.succeed("ls -la --time-style=full-iso /boot/EFI/Linux/")
    t0 = appliance.succeed("date '+%Y-%m-%d %H:%M:%S'").strip()
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=300)
    journal = appliance.succeed(
      f"journalctl -u systemd-sysupdate --since '{t0}' --no-pager || true"
    )
    assert "Successfully installed" not in journal, \
        f"same version re-installed: {journal[-500:]!r}"
    after_parts = appliance.succeed("sgdisk -p /dev/vda")
    after_efi = appliance.succeed("ls -la --time-style=full-iso /boot/EFI/Linux/")
    assert before_parts == after_parts, "partition table changed on a no-op run"
    assert before_efi == after_efi, "boot entries changed on a no-op run"
    print("NOOP OK: same version → no install, no slot/boot-entry change, green exit")

    # -- The staged v2 still boots when the operator reboots ----------------
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "2", f"post-noop reboot: expected v2, got {version}"
    print("PASS: no-op is inert; the installed v2 boots on demand")
  '';
}

# ab-ota-migrate-boot-vm — the DISK side of live→OTA migration: the first OTA
# boot on a migrated disk whose GPT labels and ESP content come from the live
# era. Companion to ab-ota-migrate-vm (which pins the live-side switch and
# never boots the staged image; this suite owns the cutover itself).
#
#   Legacy disk (built host-side via image.repart, the classic NixOS layout):
#     p1 ESP  (partlabel "ESP",   vfat) — systemd-boot fallback + loader.conf
#                                         carrying the live-era `default
#                                         nixos-*` pin + one Type#1 entry
#     p2 root (partlabel "nixos", ext4) — the toplevel closure + seeded /etc
#     free space at the end (2 x 512M slots fit)
#
#   systemd-boot v261 semantics under test (src/boot/boot.c):
#     * entry sort: tries_left==0 LAST, then sort-key strcmp ASC, then
#       version DESC. The UKI's sort-key is its os-release IMAGE_ID
#       ("abtest") — it orders before the legacy "nixos" sort-key.
#     * the `default` glob is NOT boot-assessment-aware: an exhausted UKI
#       still matches `default abtest_*.efi` and would be re-booted forever.
#       Arming therefore means REMOVING the live-era pin, never replacing it
#       with a UKI-only glob.
#
#   Legs:
#     A1 unarmed staging: v2 staged (slot B written, UKI dropped) but
#        `default nixos-*` untouched → reboot boots the LEGACY entry.
#     A2 armed, labels wrong: pin removed → the UKI is selected, its systemd
#        initrd waits for /dev/disk/by-partlabel/root (absent) → device
#        timeout → hang; the driver hard-resets; tries exhaust → the
#        exhausted entry sorts last → LEGACY boots. (The rollback net under
#        the exact operator failure mode.)
#     B  contract honoured (default variant): sgdisk relabel p2→root /
#        p1→boot + re-arm the UKI (+0 → +3 rename; boot counting is
#        filename-based) → v2 boots, blesses, the legacy entry stays on the
#        ESP as fallback.
#     C  (variant fileSystemsOverride): the v2 appliance is built with
#        fileSystems."/" mkForce'd at by-label/nixos (/boot at by-label/ESP)
#        → cutover succeeds with legacy labels untouched.
#
#   All staging is SIGNED (the legacy system carries the test pubring →
#   Transfer.Verify=yes from the first pull on): the migration path verifies
#   signatures end to end. Negative verification space (wrong key / tampered
#   / unsigned) is owned by ab-ota-verify-vm and not duplicated here.
#
# Needs KVM. Hermetic: v2 comes from the deployer node on the test LAN.
{ nixpkgs, self, system ? "x86_64-linux", fileSystemsOverride ? false, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; } }:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) fixture pkgs lib;

  efiArch = pkgs.stdenv.hostPlatform.efiArch;

  # The legacy live system: deploy-target + slot provisioning on free space,
  # classic scripted initrd mounting by FS label — no ab-image import (the
  # two-phase flip: provisioning lands first, image building comes later).
  legacyCfg = { config, lib, pkgs, ... }: {
    system.stateVersion = config.system.nixos.release;
    networking.hostName = "legacymig";
    nixpkgs.hostPlatform = system;

    fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
    fileSystems."/boot" = { device = "/dev/disk/by-label/ESP"; fsType = "vfat"; options = [ "umask=0077" ]; };

    boot.loader.grub.enable = false;
    # Asserted by deploy-target.ab. The hand-crafted legacy entry carries no
    # tries, so boot-complete.target is never pulled on the legacy system —
    # the health signal there is multi-user.target.
    boot.loader.systemd-boot.bootCounting.enable = true;
    boot.kernelParams = [ "console=ttyS0" ];
    systemd.sysupdate.enable = true;

    services.nixtache.deploy-target = {
      enable = true;
      ab = {
        enable = true;
        partitions = {
          enable = true;
          slotSize = "512M";
          autoInit = true;
          imageId = "abtest";
          source = "http://deployer/ab-stage/abtest";
          slot_a = { type = "partition"; storage = "/dev/vda"; };
          slot_b = { type = "partition"; storage = "/dev/vda"; };
          # The migration path verifies signatures from the first pull on:
          # the provision module installs the pubring, derives
          # Transfer.Verify=yes and equips the sysupdate units with gnupg.
          publicKeyFile = "${fixture.testSignKey}/pubring.pgp";
        };
      };
    };

    environment.systemPackages = with pkgs; [ gptfdisk util-linux ];

    networking.usePredictableInterfaceNames = false;
    networking.useDHCP = false;
    networking.interfaces.eth0.ipv4.addresses = [
      { address = "192.168.1.3"; prefixLength = 24; }
    ];
    networking.hosts."192.168.1.1" = [ "deployer" ];
    networking.firewall.enable = false;

    system.image.id = "legacy";
    image.repart = {
      enable = true;
      # 512M ESP + 2G root leaves ~1.5G free for 2 x 512M slots. The ext4
      # holds a full store closure (tens of thousands of small files) — the
      # default bytes-per-inode ratio exhausts inodes before space, so the
      # inode count is set explicitly.
      imageSize = "4G";
      mkfsOptions.ext4 = [ "-N" "500000" ];
      partitions = {
        "10-esp" = {
          repartConfig = {
            Type = "esp"; Label = "ESP"; Format = "vfat";
            SizeMinBytes = "512M"; SizeMaxBytes = "512M";
          };
          contents = {
            "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
            # The live-era loader.conf exactly as NixOS's systemd-boot
            # installer writes it: `default nixos-*` (systemd-boot-builder
            # write_loader_conf).
            "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
              timeout 3
              default nixos-*
            '';
            "/loader/entries/nixos-generation-1.conf".source = pkgs.writeText "nixos-generation-1.conf" ''
              title NixOS
              version Generation 1 (legacy live system), built on 2026-01-01
              sort-key nixos
              linux /EFI/nixos/kernel
              initrd /EFI/nixos/initrd
              options init=${config.system.build.toplevel}/init ${lib.concatStringsSep " " config.boot.kernelParams}
            '';
            "/EFI/nixos/kernel".source = "${config.system.build.toplevel}/kernel";
            "/EFI/nixos/initrd".source = "${config.system.build.toplevel}/initrd";
          };
        };
        "20-root" = {
          storePaths = [ config.system.build.toplevel ];
          contents = {
            # Seed /etc so the first boot mounts /boot without waiting for
            # activation to materialize fstab mid-boot.
            "/etc".source = config.system.build.etc;
          };
          repartConfig = {
            Type = "linux-generic"; Label = "nixos"; Format = "ext4";
            SizeMinBytes = "2048M"; SizeMaxBytes = "2048M";
          };
        };
      };
    };
  };

  legacySystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      (nixpkgs + "/nixos/modules/image/repart.nix")
      (nixpkgs + "/nixos/modules/testing/test-instrumentation.nix")
      (nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
      self.nixosModules.deploy-target
      legacyCfg
    ];
  };
  legacyImage = "${legacySystem.config.system.build.image}/legacy.raw";

  # The OTA payload. Default variant: the image mounts / and /boot by the
  # GPT partlabels root/boot (module defaults). Override variant: the
  # consumer mkForce's the devices at the legacy FS labels instead — the
  # initrd's fstab is generated from config.fileSystems (root=fstab), so the
  # override flows into the UKI and the appliance boots the existing
  # partitions without relabeling.
  v2 = otaLib.mkAppliance ({ version = "2"; extraPackages = [ pkgs.hello ]; }
    // lib.optionalAttrs fileSystemsOverride {
      extraModules = [
        ({ lib, ... }: {
          fileSystems."/".device = lib.mkForce "/dev/disk/by-label/nixos";
          fileSystems."/boot".device = lib.mkForce "/dev/disk/by-label/ESP";
        })
      ];
    });
  v2Pkg = v2.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "ab-ota-migrate-boot";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ v2Pkg ]; };

  testScript = ''
    def create_legacy_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand legacyImage}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def burn_boot(m):
        # The UKI attempt hangs in the appliance initrd (90s device timeout
        # for the absent by-partlabel/root, then an emergency wait) — but
        # systemd is pid1 and still answers ctrl-alt-delete, so a clean
        # driver reboot works and (unlike a QMP system_reset) marks the
        # shell disconnected so the next command resyncs.
        m.reboot()

    deployer.start()
    deployer.wait_for_unit("nginx.service")

    legacy = create_legacy_machine(name="legacy")
    legacy.start(allow_reboot=True)
    legacy.wait_for_unit("multi-user.target")
    assert legacy.succeed("hostname").strip() == "legacymig"

    # -- Migration phase 1: slots provisioned on the legacy disk's free space
    legacy.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_1", timeout=300)
    legacy.wait_until_succeeds("sgdisk -p /dev/vda | grep -q _empty", timeout=300)
    print("OK: slots provisioned on the legacy disk's free space")

    # -- Stage v2 SIGNED (the migration path verifies from the first pull) --
    legacy.succeed("test -f /etc/systemd/import-pubring.pgp")
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/ && "
      "cd /var/lib/nixtache/ab-stage/abtest && "
      "sha256sum *.raw *.efi *.lower-db > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS && "
      "export GNUPGHOME=$(mktemp -d) && "
      "${pkgs.gnupg}/bin/gpg --batch --import ${fixture.testSignKey}/priv.asc 2>/dev/null && "
      "${pkgs.gnupg}/bin/gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS"
    )
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abtest/SHA256SUMS.gpg")
    print("OK: v2 staged signed (SHA256SUMS.gpg present)")
    legacy.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    legacy.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    legacy.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+3.efi", timeout=300)
    print("OK: v2 staged (nix-store_2 written, UKI on the ESP, tries=3)")

    # -- Leg A1: unarmed staging — the live-era pin keeps the UKI from booting
    legacy.reboot()
    legacy.wait_for_unit("multi-user.target")
    assert legacy.succeed("hostname").strip() == "legacymig"
    # Tries intact: the UKI was never selected.
    legacy.succeed("test -f /boot/EFI/Linux/abtest_2+3.efi")
    print("LEG A1 OK: `default nixos-*` pin — staged UKI not selected, legacy boots")

    # Arming: REMOVE the live-era pin (a UKI-only default glob is not
    # assessment-aware and would reselect a failed image forever).
    legacy.succeed("sed -i '/^default /d' /boot/loader/loader.conf")
    legacy.fail("grep -q '^default ' /boot/loader/loader.conf")
    print("OK: armed — default pin removed")
  '' + (
    if !fileSystemsOverride then ''
      # -- Leg A2: labels still wrong → boot fails, tries exhaust, rollback --
      # Self-describing loop: a boot that reaches userspace on the legacy
      # hostname ends the leg; a boot that hangs (the appliance initrd
      # waiting for /dev/disk/by-partlabel/root, 90s device timeout) burns a
      # try and gets rebooted out of the hang.
      legacy_back = False
      for attempt in range(4):
          burn_boot(legacy)
          try:
              legacy.wait_for_unit("multi-user.target", timeout=220)
              booted = legacy.succeed("hostname").strip()
              print(f"LEG A2 attempt {attempt + 1}: reached userspace as {booted}")
              if booted == "legacymig":
                  legacy_back = True
                  break
              raise Exception(f"unexpected userspace boot: {booted}")
          except Exception as e:
              if "unexpected userspace" in str(e):
                  raise
              print(f"LEG A2 attempt {attempt + 1}: no userspace (UKI hung in initrd — try burned)")
      assert legacy_back, "LEG A2 FAIL: never returned to the legacy entry"
      legacy.wait_until_succeeds("ls /boot/EFI/Linux/abtest_2+0-*.efi", timeout=60)
      print("LEG A2 OK: exhausted UKI skipped, legacy entry booted (rollback net held)")

      # -- Leg B: contract honoured — relabel, re-arm, cut over -------------
      legacy.succeed("sgdisk --change-name=2:root /dev/vda")
      legacy.succeed("sgdisk --change-name=1:boot /dev/vda")
      legacy.succeed("udevadm settle || true")
      # Re-arm the exhausted UKI (boot counting is filename-based).
      legacy.succeed("mv /boot/EFI/Linux/abtest_2+0-*.efi /boot/EFI/Linux/abtest_2+3.efi")
      print("OK: partitions relabeled root/boot, UKI re-armed")
    '' else ''
      # -- Leg C: override hatch — labels untouched, fileSystems mkForce'd ---
      print("OK: override variant — cutover proceeds with legacy labels kept")
    ''
  ) + ''
    # -- Cutover: the armed UKI is the sorted-first candidate ----------------
    legacy.reboot()
    legacy.wait_for_unit("multi-user.target", timeout=900)
    assert legacy.succeed("hostname").strip() == "abtest"
    assert legacy.succeed("cat /etc/image-version").strip() == "2"
    legacy.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    legacy.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2.efi", timeout=120)
    print("OK: v2 booted and blessed (tries suffix dropped)")

    # Content marker: v2 ships hello.
    legacy.succeed("hello | grep -q 'Hello'")
  '' + (
    # findmnt reports the resolved device, not the symlink used at mount
    # time — assert the contracted symlink resolves to the mounted source.
    if !fileSystemsOverride then ''
      legacy.succeed("test \"$(findmnt -n -o SOURCE /)\" = \"$(readlink -f /dev/disk/by-partlabel/root)\"")
      legacy.succeed("test \"$(findmnt -n -o SOURCE /boot)\" = \"$(readlink -f /dev/disk/by-partlabel/boot)\"")
    '' else ''
      legacy.succeed("test \"$(findmnt -n -o SOURCE /)\" = \"$(readlink -f /dev/disk/by-label/nixos)\"")
      legacy.succeed("test \"$(findmnt -n -o SOURCE /boot)\" = \"$(readlink -f /dev/disk/by-label/ESP)\"")
    ''
  ) + ''
    # The live-era entry stays on the ESP as the bootable fallback.
    legacy.succeed("test -f /boot/loader/entries/nixos-generation-1.conf")
    legacy.succeed("test -f /boot/EFI/nixos/kernel")
    # Update machinery functional after the cutover (instance listing works —
    # same update-awareness probe as ab-ota-rollback-vm).
    legacy.succeed("systemd-sysupdate list > /dev/null")
    print("LEG B/C OK: cutover blessed, fallback retained, update machinery alive")

    print("PASS: migrated disk cutover — pin/rollback/contract legs all green")
  '';
}

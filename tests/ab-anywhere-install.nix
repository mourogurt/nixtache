# The consumer-style system that tests/ab-ota-anywhere-vm.nix installs onto the
# bare target disk via nixos-anywhere. A standalone function of the flake
# inputs so the SAME expression evaluates in two places:
#   1. on the host — to pre-build toplevel / diskoScript / sysupdate-package /
#      UKI into the test's store closure (system.extraDependencies);
#   2. inside the deployer VM — the generated install flake re-evaluates it
#      during `nixos-anywhere --flake ...`; every input is the identical store
#      path (path: flake inputs), so the derivations hash-match and the VM's
#      `nix build` is always a store no-op (the VMs have no internet).
#
# The config is a real consumer wiring: nixtache's deploy-target + ab-image
# modules (via the fixture's mkAppliance) + a disko A/B layout (ESP + two
# nix-store slots + ext4 root on one disk) + signature verification ON
# (publicKeyFile → Transfer.Verify=yes).
#
# nixtache is taken apart into nixtachePath (fixture source) + nixtacheModules
# (the two NixOS modules) so the deployer-VM flake can vendor the needed
# subtree into its own flake directory — pure flake evaluation forbids
# referencing absolute store paths, and a path: input would need a narHash
# the host cannot compute for the dirty worktree.
{ nixpkgs, nixtachePath, nixtacheModules, disko, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  fixture = import (nixtachePath + "/tests/ab-fixture.nix") {
    inherit nixpkgs system;
    # mkAppliance only reads self.nixosModules.
    self = { nixosModules = nixtacheModules; };
  };
in
fixture.mkAppliance {
  # The installed system IS v1: disko labels slot A `nix-store_1` and the ESP
  # UKI is `abtest_1+<tries>.efi`. The test stages v2 over OTA afterwards.
  version = "1";
  signVerify = true; # pubring + Transfer.Verify=yes — unsigned updates are rejected
  stagingPath = "http://deployer/ab-stage/abanywhere"; # the deployer's nginx vhost
  storeSize = "1G"; # matches the disko slot partitions below
  deployKeyPub = fixture.deployKeyPub; # the deploy action SSHes in as nixos-deploy
  extraPackages = with fixture.pkgs; [
    squashfsTools # unsquashfs -l on the slots (content assertions)
    gptfdisk # sgdisk -p (GPT label assertions)
    curl # pull the staged v1 store into slot A over HTTP
  ];
  extraModules = [
    (disko + "/module.nix")
    (
      { lib, modulesPath, ... }:
      {
        imports = [
          # The test driver talks to the installed machine via the backdoor
          # root shell on the virtio console (same mechanism nixos-anywhere's
          # own test suite uses for its installed machine).
          (modulesPath + "/testing/test-instrumentation.nix")
          # virtio blk/net/console in the initrd — the installed disk boots in
          # a fresh QEMU (OVMF) that attaches it as virtio-blk.
          (modulesPath + "/profiles/qemu-guest.nix")
        ];

        networking.hostName = lib.mkForce "abanywhere";

        # The deployer VM re-evaluates this config with nixpkgs as a path:
        # flake input (no git sourceInfo), while the host pre-build sees the
        # github-fetched one — versionSuffix/revision would differ
        # ("...20260804.dfce2e0" vs "...19700101.dirty"), producing different
        # derivations and forcing a real (offline-doomed) build in the VM.
        # Pinning both keeps the two evaluations bit-identical (same trick as
        # nixpkgs' nix-builder profile).
        system.nixos.versionSuffix = ".test";
        system.nixos.revision = null;

        # nixos-install finishes with `switch-to-configuration boot`; the
        # image-based-appliance profile (pulled in by ab-image) removes that
        # entrypoint, so re-enable it. No boot loader is enabled, so its
        # installBootLoader step is a no-op warning — the ESP is populated
        # out-of-band via nixos-anywhere --extra-files with the same files
        # ab-image's repart ESP contents would carry (systemd-boot UEFI
        # fallback + the UKI + loader.conf).
        system.switch.enable = lib.mkForce true;

        # Root ext4 + ESP come from the disko layout; /nix/store stays on the
        # root filesystem — nixos-anywhere installs a closure, it cannot write
        # raw image slots, so the A/B slots are out-of-band update partitions
        # written only by systemd-sysupdate (the same separation of concerns
        # as the extra-disk layout in tests/ab-ota-e2e.nix). ab-image's
        # by-partlabel /nix/store mount (the squashfs slot) is replaced
        # wholesale — disko creates the slot partitions but leaves them raw.
        fileSystems = lib.mkForce {
          "/" = {
            device = "/dev/disk/by-partlabel/root";
            fsType = "ext4";
          };
          "/boot" = {
            device = "/dev/disk/by-partlabel/boot";
            fsType = "vfat";
          };
        };

        # Single-disk A/B layout: ESP + two nix-store slots + ext4 root. The
        # GPT labels are the sysupdate A/B contract — one written slot
        # (nix-store_1) + one free slot (_empty), type 8300 = systemd's
        # "linux-generic" partition type the nix-store transfer matches on.
        # Priorities fix the on-disk order (esp=1, slot A=2, slot B=3,
        # root=4); the 100% partition is created last by default. The device
        # is the target VM's SECOND disk (virtualisation.emptyDiskImages) —
        # the node's own boot disk is never touched.
        disko.devices.disk.main = {
          device = "/dev/vdb";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              esp = {
                priority = 100;
                size = "300M";
                type = "EF00";
                label = "boot";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };
              slot-a = {
                priority = 200;
                size = "1G";
                label = "nix-store_1";
              };
              slot-b = {
                priority = 300;
                size = "1G";
                label = "_empty";
              };
              root = {
                size = "100%";
                label = "root";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };

        # Static test-LAN address: the post-install machine is created
        # dynamically by the test driver, so it is not in the driver's
        # allMachines name/IP map. Node numbers 1/2 are deployer/target
        # (alphabetical) — 3 is free. The hosts entry resolves the sysupdate
        # Source URL's `deployer` host part.
        networking.usePredictableInterfaceNames = false;
        networking.interfaces.eth0.ipv4.addresses = [
          {
            address = "192.168.1.3";
            prefixLength = 24;
          }
        ];
        networking.hosts."192.168.1.1" = [ "deployer" ];
        networking.firewall.enable = false;

        # ab-image targets receive no `nix copy` closure pushes (the OTA
        # payload is the sysupdate-package) and the appliance profile disables
        # nix — no store trust configuration here (the deploy-user module adds
        # trusted-users unconditionally; on a nix-less appliance it is inert).
      }
    )
  ];
}

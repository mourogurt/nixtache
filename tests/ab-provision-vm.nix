# QEMU (runNixOSTest) BEHAVIORAL CONTRACT for the not-yet-implemented module
# `services.nixtache.deploy-target.ab.partitions.*` (spec 08 §1–§4).
#
# Regular NixOS VM nodes (NOT an appliance image) with extra empty disks; each
# node imports `self.nixosModules.deploy-target` and sets the FUTURE
# `ab.partitions.*` option, then we assert on real sgdisk partition tables.
# The test FAILS NOW (option absent → node eval refuses) and turns green once
# an implementing agent creates `modules/deploy-target/ab-provision.nix`.
#
# Covers (TEST-SPECS.md §2): P1 init, P2 idempotent, P3 second-disk, S1 size-error,
# S2 size-wipe, S3 no-space, S4 percent, PR1 protected-label. Needs KVM.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Common config for every provision-test node: sysupdate + bootCounting are
  # required by the existing `ab.enable` assertion; gptfdisk/util-linux to read
  # the partition tables we assert on. (nixpkgs.hostPlatform is NOT set here —
  # runNixOSTest sets it per node from the test's `system`.)
  common = { pkgs, ... }: {
    systemd.sysupdate.enable = true;                      # ab.enable assert requires it
    boot.loader.systemd-boot.bootCounting.enable = true;  # ab.enable assert requires it
    services.nixtache.deploy-target = {
      enable = true;
      ab.enable = true;
      ab.gating = false;
    };
    environment.systemPackages = with pkgs; [ gptfdisk util-linux e2fsprogs ];
  };

  # One node. `disks` → virtualisation.emptyDiskImages (MiB). `part-extra`
  # overrides ab.partitions.*. `pre-part` (optional) → a oneshot that lays down
  # a starting GPT before nixtache-ab-provision runs (for S1/S2/S3/PR1).
  mkNode = { disks ? [ 4096 ], part-extra ? { }, pre-part ? null }:
    { config, lib, pkgs, ... }: {
      imports = [ self.nixosModules.deploy-target common ];
      virtualisation.emptyDiskImages = disks;
      services.nixtache.deploy-target.ab.partitions = lib.recursiveUpdate
        {
          enable = true;
          slotSize = "512M";
          autoInit = false;
          onSizeMismatch = "error";
          protectedLabels = [ "root" "esp" "boot" ];
          slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
          slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
        }
        part-extra;
      systemd.services.ab-pre-partition = lib.mkIf (pre-part != null) {
        description = "Pre-create GPT slots for provision tests";
        wantedBy = [ "multi-user.target" ];
        before = [ "nixtache-ab-provision.service" ];
        path = with pkgs; [ gptfdisk util-linux e2fsprogs ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = pre-part;
      };
    };

  # partition size in bytes via lsblk (robust for block devices)
  partSize = dev: "lsblk -bno SIZE ${dev} | head -1";
in
pkgs.testers.runNixOSTest {
  name = "ab-provision";

  nodes = {
    # P1: empty disk + autoInit → two slots created at slotSize.
    p1_init = mkNode { disks = [ 4096 ]; part-extra = { autoInit = true; }; };

    # P2: identical to P1 — idempotency checked by restart in the testScript.
    p2_idem = mkNode { disks = [ 4096 ]; part-extra = { autoInit = true; }; };

    # P3: slots on /dev/vdc (second disk); /dev/vdb must stay untouched.
    p3_second = mkNode {
      disks = [ 4096 4096 ];
      part-extra = {
        autoInit = true;
        slot_a.storage = "/dev/vdc";
        slot_b.storage = "/dev/vdc";
      };
    };

    # S1: pre-made 512M slots, slotSize=1G, onSizeMismatch=error → keep slots,
    # log mismatch, block sysupdate.
    s1_error = mkNode {
      disks = [ 4096 ];
      part-extra = { slotSize = "1G"; onSizeMismatch = "error"; };
      pre-part = ''
        sgdisk --zap-all /dev/vdb
        sgdisk --new=1:0:+512M --typecode=1:8300 --change-name=1:nix-store_1 /dev/vdb
        sgdisk --new=2:0:+512M --typecode=2:8300 --change-name=2:_empty /dev/vdb
        udevadm settle
      '';
    };

    # S2: pre-made 512M slots (with marker data), slotSize=1G, wipe → both
    # recreated (nix-store_1 + _empty) at the new size.
    s2_wipe = mkNode {
      disks = [ 4096 ];
      part-extra = { slotSize = "1G"; onSizeMismatch = "wipe"; };
      pre-part = ''
        sgdisk --zap-all /dev/vdb
        sgdisk --new=1:0:+512M --typecode=1:8300 --change-name=1:nix-store_1 /dev/vdb
        sgdisk --new=2:0:+512M --typecode=2:8300 --change-name=2:_empty /dev/vdb
        udevadm settle
        dd if=/dev/urandom of=/dev/vdb1 bs=1M count=4 2>/dev/null || true
      '';
    };

    # S3: disk filled by one partition, slotSize=2G, autoInit=true → no space,
    # provision fails with a clear message.
    s3_nospace = mkNode {
      disks = [ 512 ];
      part-extra = { slotSize = "2G"; autoInit = true; };
      pre-part = ''
        sgdisk --zap-all /dev/vdb
        sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:filler /dev/vdb
        udevadm settle
      '';
    };

    # S4: slotSize="10%" on a 2GB disk → each slot ≈ 200M.
    s4_percent = mkNode {
      disks = [ 2048 ];
      part-extra = { slotSize = "10%"; autoInit = true; };
    };

    # PR1: protected 'data' partition overlapping the wipe zone → provision must
    # refuse rather than destroy data.
    pr1_protected = mkNode {
      disks = [ 4096 ];
      part-extra = {
        slotSize = "1G";
        onSizeMismatch = "wipe";
        protectedLabels = [ "root" "esp" "boot" "data" ];
      };
      pre-part = ''
        sgdisk --zap-all /dev/vdb
        sgdisk --new=1:0:+256M --typecode=1:8300 --change-name=1:data /dev/vdb
        sgdisk --new=2:0:+512M --typecode=2:8300 --change-name=2:nix-store_1 /dev/vdb
        sgdisk --new=3:0:+512M --typecode=3:8300 --change-name=3:_empty /dev/vdb
        udevadm settle
        mkfs.ext4 -q /dev/vdb1
        mkdir -p /mnt/data && mount /dev/vdb1 /mnt/data
        echo MARKER > /mnt/data/survival
        umount /mnt/data
      '';
    };
  };

  testScript = ''
    # ── P1: empty disk + autoInit → two slots at slotSize ─────────────────
    p1_init.start()
    p1_init.wait_for_unit("nixtache-ab-provision.service")
    p1_init.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    p1_init.succeed("sgdisk -p /dev/vdb | grep _empty")
    p1_init.succeed("test $(${partSize "/dev/vdb1"}) -gt 480000000")   # ~512M, >480M
    p1_init.succeed("test $(${partSize "/dev/vdb1"}) -lt 580000000")   # <580M
    print("P1 OK: autoInit created nix-store_1 + _empty at ~512M")

    # ── P2: idempotent — restart does not change the partition table ──────
    p2_idem.start()
    p2_idem.wait_for_unit("nixtache-ab-provision.service")
    before = p2_idem.succeed("sgdisk -p /dev/vdb | sha256sum")
    p2_idem.succeed("systemctl restart nixtache-ab-provision.service")
    p2_idem.wait_for_unit("nixtache-ab-provision.service")
    after = p2_idem.succeed("sgdisk -p /dev/vdb | sha256sum")
    assert before == after, "P2 FAIL: provision was not idempotent"
    print("P2 OK: provision idempotent (partition table unchanged on restart)")

    # ── P3: second disk — slots on /dev/vdc, /dev/vdb untouched ───────────
    p3_second.start()
    p3_second.wait_for_unit("nixtache-ab-provision.service")
    p3_second.succeed("sgdisk -p /dev/vdc | grep nix-store_1")
    p3_second.succeed("sgdisk -p /dev/vdc | grep _empty")
    p3_second.fail("sgdisk -p /dev/vdb | grep -E 'nix-store_1|_empty'")
    print("P3 OK: slots on /dev/vdc; /dev/vdb untouched")

    # ── S1: size mismatch, onSizeMismatch=error → slots intact, mismatch logged
    s1_error.start()
    s1_error.wait_for_unit("nixtache-ab-provision.service")
    s1_error.succeed("sgdisk -p /dev/vdb | grep nix-store_1")  # old 512M slot preserved
    s1_error.succeed("journalctl -u nixtache-ab-provision --no-pager | grep -i mismatch")
    print("S1 OK: size mismatch detected, slots preserved, message logged")

    # ── S2: size mismatch, onSizeMismatch=wipe → both slots recreated at new size ──
    s2_wipe.start()
    s2_wipe.wait_for_unit("nixtache-ab-provision.service")
    # After wipe both slots are recreated as nix-store_1 + _empty (configured
    # labels, new size) — the sysupdate-native layout: one written-slot label
    # + one free-slot marker.
    s2_wipe.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    s2_wipe.succeed("sgdisk -p /dev/vdb | grep _empty")
    # New size: ~1G (was 512M in pre-part).
    s2_wipe.succeed("test $(${partSize "/dev/vdb1"}) -gt 900000000")
    s2_wipe.succeed("test $(${partSize "/dev/vdb2"}) -gt 900000000")
    # Idempotent on restart: Normal state (slots present) + sizes match → no-op.
    before = s2_wipe.succeed("sgdisk -p /dev/vdb | sha256sum")
    s2_wipe.succeed("systemctl restart nixtache-ab-provision.service")
    s2_wipe.wait_for_unit("nixtache-ab-provision.service")
    after = s2_wipe.succeed("sgdisk -p /dev/vdb | sha256sum")
    assert before == after, "S2 FAIL: provision was not idempotent after wipe"
    print("S2 OK: wipe recreated both slots at new size (nix-store_1+_empty); idempotent on restart")

    # ── S3: no free space, autoInit=true → provision fails clearly ────────
    s3_nospace.start()
    s3_nospace.wait_until_succeeds("systemctl is-failed nixtache-ab-provision.service")
    s3_nospace.succeed("journalctl -u nixtache-ab-provision --no-pager | grep -iE 'free space|no space|not enough'")
    print("S3 OK: no-space case refused with a clear message")

    # ── S4: percent slotSize → each slot ≈ 10% of 2G (≈200M) ──────────────
    s4_percent.start()
    s4_percent.wait_for_unit("nixtache-ab-provision.service")
    s4_percent.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    s4_percent.succeed("test $(${partSize "/dev/vdb1"}) -gt 150000000")   # >150M
    s4_percent.succeed("test $(${partSize "/dev/vdb1"}) -lt 260000000")   # <260M
    print("S4 OK: 10% slotSize resolved to ~200M")

    # ── PR1: protected 'data' partition → provision refuses, data survives ─
    pr1_protected.start()
    pr1_protected.wait_until_succeeds("systemctl is-failed nixtache-ab-provision.service")
    pr1_protected.succeed("mount /dev/vdb1 /mnt/data")
    pr1_protected.succeed("grep MARKER /mnt/data/survival")
    print("PR1 OK: protected 'data' partition untouched on refused wipe")
  '';
}

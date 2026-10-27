# ab-data-pool-vm — consumer storage OUTSIDE the A/B slots across OTA swaps
# (the reference-server shape: a ZFS pool holding service state, plus the
# overlay-nix writable upper living on that pool).
#
#   Appliance (driver-created, OVMF → ESP fallback → UKI; the
#   ab-ota-swap mechanism) with TWO virtio disks:
#     vda: the A/B appliance image (ESP + nix-store_1 + _empty + root)
#     vdb: blank 1G — the test creates a ZFS pool `tank` on it at first boot
#
#   The appliance config mirrors the server: boot.zfs.extraPools = ["tank"],
#   overlay-nix with upperDir/workDir on a pool dataset. Signing is on
#   (signVerify): pulls verify the staged manifest end to end.
#
#   Flow:
#     1. v1 boots (no pool yet — first boot tolerates its absence), the test
#        creates tank, writes state, restarts the overlay mount onto the pool
#        dirs and realizes vim into the overlay upper (from the deployer's
#        nix-serve; hermetic LAN).
#     2. v2 staged signed → sysupdate writes slot B → reboot into v2:
#        the pool imports (zpool.cache lives on the persistent root), state
#        reads, the probe unit is active, vim still runs from the upper, and
#        v2's hello marker is visible through the merged store.
#     3. Rollback leg: rename the blessed v1 UKI to sort newest (simulates
#        falling back to the previous slot; the boot-counting fallback itself
#        is ab-ota-rollback-vm's domain) → v1 boots, the pool still imports
#        (no zpool upgrade anywhere — slot version drift must not wedge data)
#        and the upper still serves vim.
#
# Needs KVM. Hermetic: everything comes from the deployer node on the test LAN.
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) fixture pkgs lib;

  vimPath = pkgs.vim.outPath;
  vimBasename = baseNameOf vimPath;
  helloBasename = baseNameOf pkgs.hello.outPath;

  mkPoolAppliance = { version, extraPackages ? [ ] }:
    otaLib.mkAppliance {
      inherit version;
      signVerify = true;
      storeSize = "1G";
      extraPackages = extraPackages ++ [ pkgs.zfs ];
      extraModules = [
        self.nixosModules.overlay-nix
        ({ lib, ... }: {
          networking.hostId = "8425e349"; # required by ZFS
          networking.useDHCP = false;

          # The data pool outside the slots (server: srv-root). Created
          # in-test on first boot; imported on every later boot.
          boot.supportedFilesystems = [ "zfs" ];
          boot.zfs.extraPools = [ "tank" ];

          # The writable upper layer lives ON THE POOL (server: /srv on
          # ZFS). OverlayFS-upper-on-ZFS is supported since OpenZFS 2.2
          # (d_type + renameat2 whiteout/exchange, openzfs/zfs#8648 → #9414);
          # this suite pins it on the pinned versions, including the mount
          # ordering against zfs-mount.
          services.nixtache.overlay-nix = {
            enable = true;
            upperDir = "/tank/nix-overlay/upper";
            workDir = "/tank/nix-overlay/work";
          };

          # Boot-time probe: services backed by the pool see their state.
          # ConditionPathExists skips the FIRST boot (pool not yet created);
          # on later boots a skipped or failed probe fails the test's
          # is-active assert either way.
          systemd.services.tank-probe = {
            description = "probe: service state on the data pool is readable";
            wantedBy = [ "multi-user.target" ];
            unitConfig.ConditionPathExists = "/tank/state.txt";
            after = [ "zfs-mount.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''test "$(cat /tank/state.txt)" = "v1-state"'';
          };
        })
      ];
    };

  v1 = mkPoolAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = mkPoolAppliance { version = "2"; extraPackages = [ pkgs.hello ]; };
  v2Pkg = v2.config.system.build.sysupdate-package;

  # Blank data disk (sparse 1G). qemu snapshot=on keeps run-time writes in a
  # COW overlay — the backing file stays pristine and the pool is re-created
  # from scratch each run.
  dataDisk = pkgs.runCommand "ab-data-pool-disk" { } ''
    dd if=/dev/zero of=$out bs=1M count=0 seek=1024
  '';

  startCommand = image:
    lib.concatStringsSep " " [
      "${pkgs.qemu_test}/bin/qemu-kvm"
      "-machine q35"
      "-cpu max"
      "-accel kvm"
      "-accel tcg"
      "-bios ${pkgs.OVMF.fd}/FV/OVMF.fd"
      "-m 3072"
      "-smp 4"
      "-drive file=${image},id=drive1,if=none,werror=report,snapshot=on"
      "-device virtio-blk-pci,drive=drive1,bootindex=1"
      # serial= gives the disk a /dev/disk/by-id/ entry — NixOS's zfs-import
      # scans /dev/disk/by-id (boot.zfs.devNodes default), so without a serial
      # the pool would be unfindable after a reboot.
      "-drive file=${dataDisk},id=drive2,if=none,werror=report,snapshot=on"
      "-device virtio-blk-pci,drive=drive2,serial=datadisk"
      "-netdev vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1"
      "-device virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03"
    ];
in
pkgs.testers.runNixOSTest {
  name = "ab-data-pool";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ v2Pkg pkgs.vim ]; };

  testScript = ''
    def create_pool_machine(**kwargs):
        machine = create_machine(start_command="${startCommand v1Image}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    deployer.start()
    deployer.wait_for_unit("nginx.service")
    deployer.wait_for_unit("nix-serve.service")

    appliance = create_pool_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    # Bless v1 first (boot-complete reached) — else its remaining tries would
    # outrank the freshly installed v2 entry at the swap reboot.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("OK: v1 appliance booted and blessed")

    # -- First boot: the pool does not exist yet -----------------------------
    appliance.fail("zpool status tank")
    # systemd-tmpfiles pre-created /tank/nix-overlay/{upper,work} on the root
    # fs at boot (the overlay upperDir/workDir rules) and the overlay already
    # mounts ONTO them — drop that mount before replacing /tank with the pool
    # (a mounted overlay whose upperdir is unlinked serves ENOENT on writes).
    # zpool also refuses to mount over a non-empty mountpoint. On later boots
    # /tank is the pool and tmpfiles fills it if needed.
    appliance.succeed("umount -l /nix/store")
    appliance.succeed("rm -rf /tank")
    appliance.succeed("zpool create -O mountpoint=/tank tank /dev/vdb")
    appliance.succeed("echo v1-state > /tank/state.txt")
    appliance.succeed("mkdir -p /tank/nix-overlay/upper /tank/nix-overlay/work")
    # The overlay mount ran at boot when /tank was absent — remount now that
    # the pool dirs exist.
    appliance.succeed("systemctl restart nix-daemon-overlay-mount.service")
    appliance.succeed(
      "mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=/tank/nix-overlay/upper'"
    )
    print("OK: tank created; overlay remounted with the upper on the pool")

    # -- Runtime install into the overlay upper (on the pool) ----------------
    appliance.wait_until_succeeds("nix --version", timeout=300)
    appliance.succeed("nix-store --realize ${vimPath}", timeout=600)
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"vim did not run on v1 ({out!r})"
    appliance.succeed("test -d /tank/nix-overlay/upper/${vimBasename}")
    print("OK: vim realized into the pool-resident upper, runs via the merged store")

    # -- Stage v2 SIGNED + sysupdate → slot B → reboot -----------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/ && "
      "cd /var/lib/nixtache/ab-stage/abtest && "
      "sha256sum *.raw *.efi *.lower-db > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS && "
      "export GNUPGHOME=$(mktemp -d) && "
      "${pkgs.gnupg}/bin/gpg --batch --import ${fixture.testSignKey}/priv.asc 2>/dev/null && "
      "${pkgs.gnupg}/bin/gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: signed v2 staged and written to slot B + ESP")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    # The pool imports on the new slot and serves state.
    appliance.succeed("zpool status tank > /dev/null")
    appliance.succeed("test \"$(cat /tank/state.txt)\" = 'v1-state'")
    appliance.succeed("systemctl is-active --quiet tank-probe.service")
    # The overlay remounted over the NEW lower with the upper intact on the pool.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
    )
    appliance.succeed(
      "mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=/tank/nix-overlay/upper'"
    )
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"upper-layer tool lost across the swap ({out!r})"
    appliance.succeed("test -d /nix/store/${helloBasename}")
    print("OK: v2 booted — pool imported, state served, upper intact, new lower visible")

    # -- Rollback leg: the previous slot must still import the pool ----------
    # Simulate the rollback with a Type#1 entry booting v1's blessed UKI:
    # same sort-key as the image entries ("abtest", from os-release IMAGE_ID)
    # but a higher version — it sorts first and boots the OLD slot. (A bare
    # filename rename does NOT work: a Type#2 entry's version comes from the
    # IMAGE_VERSION baked inside the UKI, not from the filename.) The
    # boot-counting fallback path itself is pinned by ab-ota-rollback-vm;
    # here we only need the old slot running again. No `zpool upgrade`
    # anywhere — slot version drift must not wedge consumer data.
    # The appliance ESP ships no loader/entries dir — create it.
    appliance.succeed("mkdir -p /boot/loader/entries")
    appliance.succeed(
      "printf 'title Rollback-to-v1\\nversion 99\\nsort-key abtest\\nuki /EFI/Linux/abtest_1.efi\\n' > /boot/loader/entries/zz-rollback.conf"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    appliance.succeed("zpool status tank > /dev/null")
    appliance.succeed("test \"$(cat /tank/state.txt)\" = 'v1-state'")
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"upper-layer tool lost after rollback ({out!r})"
    print("OK: rolled back to v1 — pool still imports, state served, upper intact")

    print("PASS: data pool + overlay-upper-on-ZFS across swap and rollback")
  '';
}

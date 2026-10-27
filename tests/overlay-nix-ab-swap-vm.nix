# overlay-nix-ab-swap-vm — O9 (TEST-SPECS sec. 5.10): overlay-nix across an A/B
# slot swap, on the shipped world A (the image carries the lower store DB —
# the lower-store-db change). A faithful 2-boot run against REAL appliance
# images.
#
#   1. Boot the v1 A/B appliance (real repart image: ESP + nix-store_1 slot +
#      _empty slot + shared ext4 root) in QEMU via a driver-created machine
#      (the ab-ota-anywhere-vm mechanism: OVMF → systemd-boot fallback → UKI;
#      backdoor root shell over virtconsole from test-instrumentation.nix).
#      overlay-nix is enabled: /nix/store is the ro squashFS of slot A with a
#      writable OverlayFS upper at /var/lib/nix-overlay/upper on the SHARED
#      root FS.
#   2. Delta pin: `nix-store --realize` of a path already valid in the lower
#      (gptfdisk, baked into the toplevel closure and registered by the
#      shipped DB) copies NOTHING into the upper; `nix-store --realize` of
#      vim (absent from the lower) fetches exactly the missing paths into
#      the upper; vim runs.
#   3. The deployer stages the v2 sysupdate-package over HTTP (nginx);
#      `systemctl start systemd-sysupdate.service` on the appliance writes
#      slot B (relabelled nix-store_2) + drops abtest_2+*.efi on the ESP.
#      The module-default lifecycle policy ("wipe") clears the upper and the
#      store DB state before the slot write.
#   4. `machine.reboot()` (ctrl-alt-delete via QMP; allow_reboot=True keeps
#      QEMU's `-no-reboot` off). loader.conf has no `default` pin, so
#      systemd-boot picks the highest-version entry → abtest_2+*.efi → v2.
#      v1's UKI must be BLESSED first (boot-complete.target reached), else its
#      remaining boot-counting tries would outrank the freshly installed v2.
#   5. Assertions after the swap: /etc/image-version == 2 (v2 booted), the
#      overlay remounts over the NEW lower, the upper was wiped (vim gone,
#      its DB entry invalidated), the boot loader re-seeded the DB from v2's
#      dump (version marker "2", v2's hello VALID through standard tooling),
#      and the merged store is functional (vim realizes into the upper
#      again).
#
# Why `nix-store --realize` instead of `nix profile install`: realize takes a
# precomputed store path, so the guest needs no nixpkgs evaluation (RAM) and
# no registry source baked into the image.
#
# Needs KVM. Hermetic: vim's closure + the v2 package come from the deployer
# node on the test LAN; no internet.
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };

  vim = pkgs.vim;
  vimPath = vim.outPath;
  vimBasename = baseNameOf vimPath;
  helloPath = pkgs.hello.outPath;
  helloBasename = baseNameOf helloPath;
  # gptfdisk is baked into every appliance below (mkSwapAppliance's
  # extraPackages), so it is lower-VALID from first boot — the probe for
  # "a lower path never lands in the upper".
  gptfdiskPath = pkgs.gptfdisk.outPath;
  gptfdiskBasename = baseNameOf gptfdiskPath;

  # Throwaway binary-cache keypair: deployer signs, appliance trusts (same
  # pattern as tests/overlay-nix-install-vm.nix; self-contained on purpose).
  cacheKey = pkgs.runCommand "overlay-swap-cache-key" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export NIX_STATE_DIR=$TMPDIR/nix-state
    mkdir -p $out "$NIX_STATE_DIR"
    nix-store --generate-binary-cache-key overlay-swap-local $out/private $out/public
  '';
  cachePub = builtins.readFile "${cacheKey}/public";

  # A/B appliance + overlay-nix + test-driver plumbing (backdoor shell on
  # hvc0, virtio in initrd, static test-LAN address). The deployer is the
  # only declared node → 192.168.1.1; the created appliance machine takes .3.
  mkSwapAppliance = { version, extraPackages ? [ ] }:
    fixture.mkAppliance {
      inherit version;
      stagingPath = "http://deployer/ab-stage/abtest";
      storeSize = "1G";
      extraPackages = extraPackages ++ [ pkgs.gptfdisk ];
      extraModules = [
        self.nixosModules.overlay-nix
        (nixpkgs + "/nixos/modules/testing/test-instrumentation.nix")
        (nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
        ({ lib, ... }: {
          services.nixtache.overlay-nix.enable = true;

          # Hermetic substituter: the deployer's nix-serve (test LAN only).
          nix.settings.substituters = [ "http://deployer:5000" ];
          nix.settings.trusted-public-keys = [ cachePub ];

          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth0.ipv4.addresses = [
            { address = "192.168.1.3"; prefixLength = 24; }
          ];
          networking.hosts."192.168.1.1" = [ "deployer" ];
          networking.firewall.enable = false;
        })
      ];
    };

  v1 = mkSwapAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  # v2 carries hello as the content marker proving the new lower is visible.
  v2 = mkSwapAppliance { version = "2"; extraPackages = [ pkgs.hello ]; };
  v2SysupdatePkg = v2.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "overlay-nix-ab-swap";
  globalTimeout = 5400;

  nodes.deployer = { pkgs, ... }: {
    services.nix-serve = {
      enable = true;
      package = pkgs.nix-serve;
      secretKeyFile = "${cacheKey}/private";
      bindAddress = "0.0.0.0";
      port = 5000;
    };
    services.nginx.enable = true;
    services.nginx.virtualHosts."deployer".locations."/ab-stage/" = {
      root = "/var/lib/nixtache";
      extraConfig = "autoindex on;";
    };
    systemd.tmpfiles.rules = [ "d /var/lib/nixtache/ab-stage 1777 root root -" ];
    # the staged v2 sysupdate-package (1G store image) must fit on the root disk
    virtualisation.diskSize = 8192;
    # vim closure → served by nix-serve; the v2 package → staged over nginx.
    environment.systemPackages = [ vim ];
    system.extraDependencies = [ v2SysupdatePkg ];
    networking.firewall.enable = false;
  };

  testScript = ''
    # -- Boot the v1 appliance image as a driver-created machine (OVMF → ESP
    #    fallback → systemd-boot → UKI). snapshot=on: the store image is never
    #    mutated; writes (upper layer, slot B, ESP) live in a COW overlay that
    #    survives the in-test guest reboot. ----------------------------------
    def create_ab_machine(**kwargs):
        start_command = [
            "${pkgs.qemu_test}/bin/qemu-kvm",
            "-machine", "q35",
            "-cpu", "max",
            "-accel", "kvm",
            "-accel", "tcg",
            "-bios", "${pkgs.OVMF.fd}/FV/OVMF.fd",
            "-m", "3072",
            "-smp", "4",
            "-drive", "file=${v1Image},id=drive1,if=none,werror=report,snapshot=on",
            "-device", "virtio-blk-pci,drive=drive1,bootindex=1",
            "-netdev", "vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1",
            "-device", "virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03",
        ]
        machine = create_machine(start_command=" ".join(start_command), **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")
    # The framework's kernel cmdline carries a double-prefixed regInfo=
    # (/nix/.ro-store/nix/store/<hash>/registration) while the guest mounts
    # the host store share directly at /nix/.ro-store, so the boot-time
    # register-nix-paths.service fails with "No such file or directory" and
    # the deployer's store DB misses the extraDependencies — nix-serve then
    # cannot serve them and the appliance's realize dies with "no substituter
    # that can build it". Re-load the registration from the actually-mounted
    # path.
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    # v1 must be blessed (tries consumed) before the swap, or its remaining
    # boot-counting tries would outrank the freshly installed v2 entry.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    appliance.wait_until_succeeds("nix --version", timeout=300)
    print("OK: v1 appliance booted, overlay-nix up")

    # -- Shipped lower DB: a lower-valid path is never copied into the upper --
    # gptfdisk sits in v1's toplevel closure → the shipped dump registered it
    # at boot. Realizing it is a no-op for the upper layer (delta semantics);
    # standard tooling resolves its validity out of the box.
    appliance.succeed("nix path-info ${gptfdiskPath}")
    appliance.succeed("nix-store --realize ${gptfdiskPath}", timeout=300)
    appliance.fail("test -d /var/lib/nix-overlay/upper/${gptfdiskBasename}")
    print("OK: delta pin — lower-valid gptfdisk realized without an upper copy")

    # -- Install a tool into the overlay upper (from the deployer cache) ------
    appliance.succeed("nix-store --realize ${vimPath}", timeout=600)
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"vim did not run on v1 ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    print("OK: vim realized into the upper layer on v1")

    # -- Stage v2 + sysupdate → slot B ----------------------------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    # Type=simple upstream: `systemctl start` returns when the update process
    # LAUNCHES, not when slot B is written — poll for the GPT label + the UKI.
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: sysupdate wrote v2 to slot B + ESP")

    # -- Reboot → systemd-boot picks the highest-version UKI (abtest_2) -------
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "2", f"O9 FAIL: booted version {version}, expected 2"
    appliance.wait_until_succeeds("nix --version", timeout=300)
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
    )
    appliance.succeed(
      "mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=/var/lib/nix-overlay/upper'"
    )
    print("OK: booted v2, overlay remounted over the new lower")

    # -- Default policy ("wipe"): the upper did NOT survive the swap ----------
    # The cutover lifecycle cleared the upper + store DB state before the
    # loader re-seeded the DB from v2's shipped dump.
    appliance.fail("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    out = appliance.succeed("nix path-info ${vimPath} 2>&1 || true")
    assert "is not valid" in out, f"wipe left a DB entry for vim ({out!r})"
    marker = appliance.succeed("cat /var/lib/nixtache/lower-db-version").strip()
    assert marker == "2", f"lower DB marker {marker!r}, expected '2' (v2 dump loaded)"
    print("OK: wipe policy — upper cleared, vim's DB entry gone, DB re-seeded from v2")

    # -- v2 lower paths visible AND valid through the merged store ------------
    appliance.succeed("test -d /nix/store/${helloBasename}")
    appliance.succeed("nix path-info ${helloPath}")
    print("OK: v2 marker (hello) visible and valid in the merged /nix/store")

    # -- The merged store is functional post-swap: vim realizes again ----------
    appliance.succeed("nix-store --realize ${vimPath}", timeout=600)
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"vim did not run on v2 ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    print("OK: vim re-realized into the upper on v2 — store functional after the swap")

    print("PASS: default-policy swap — upper wiped, DB re-seeded, store functional")
  '';
}

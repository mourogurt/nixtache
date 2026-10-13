# overlay-nix-ab-swap-vm — O9 (TEST-SPECS §5.10): overlay-nix across an A/B
# slot swap. The HARDEST case in the overlay series: a faithful 2-boot run
# against REAL appliance images.
#
#   1. Boot the v1 A/B appliance (real repart image: ESP + nix-store_1 slot +
#      _empty slot + shared ext4 root) in QEMU via a driver-created machine
#      (the ab-ota-anywhere-vm mechanism: OVMF → systemd-boot fallback → UKI;
#      backdoor root shell over virtconsole from test-instrumentation.nix).
#      overlay-nix is enabled: /nix/store is the ro squashFS of slot A with a
#      writable OverlayFS upper at /var/lib/nix-overlay/upper on the SHARED
#      root FS (survives the slot swap by design — only /nix/store swaps).
#   2. `nix-store --realize` vim from the deployer's nix-serve-ng cache →
#      lands in the upper layer; vim runs.
#   3. The deployer stages the v2 sysupdate-package over HTTP (nginx);
#      `systemctl start systemd-sysupdate.service` on the appliance writes
#      slot B (relabelled nix-store_2) + drops abtest_2+*.efi on the ESP.
#   4. `machine.reboot()` (ctrl-alt-delete via QMP; allow_reboot=True keeps
#      QEMU's `-no-reboot` off). loader.conf has no `default` pin, so
#      systemd-boot picks the highest-version entry → abtest_2+*.efi → v2.
#      v1's UKI must be BLESSED first (boot-complete.target reached), else its
#      remaining boot-counting tries would outrank the freshly installed v2.
#   5. Assertions after the swap: /etc/image-version == 2 (v2 booted), the
#      overlay remounts over the NEW lower, vim from the upper layer still
#      runs (upper + its nix DB live on the shared root FS), and v2's hello
#      (marker package baked only into v2's squashFS) is visible through the
#      merged /nix/store.
#
# Why `nix-store --realize` instead of `nix profile install`: realize takes a
# precomputed store path, so the guest needs no nixpkgs evaluation (RAM) and
# no registry source baked into the image. `test -d`/`--version` assertions
# are filesystem-level: the appliance ships no lower-store nix DB, so
# `nix path-info` on lower paths is not meaningful here (the upper DB lives
# on the shared root FS and only tracks upper-layer paths).
#
# Needs KVM. Hermetic: vim's closure + the v2 package come from the deployer
# node on the test LAN; no internet.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };

  vim = pkgs.vim;
  vimPath = vim.outPath;
  vimBasename = baseNameOf vimPath;
  helloBasename = baseNameOf pkgs.hello.outPath;

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

          # Hermetic substituter: the deployer's nix-serve-ng (test LAN only).
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
      package = pkgs.nix-serve-ng;
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
    # ── Boot the v1 appliance image as a driver-created machine (OVMF → ESP
    #    fallback → systemd-boot → UKI). snapshot=on: the store image is never
    #    mutated; writes (upper layer, slot B, ESP) live in a COW overlay that
    #    survives the in-test guest reboot. ──────────────────────────────────
    def create_ab_machine(**kwargs):
        start_command = [
            "${pkgs.qemu_test}/bin/qemu-kvm",
            "-machine", "q35",
            "-cpu", "max",
            "-accel", "kvm",
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

    # ── Install a tool into the overlay upper (from the deployer cache) ──────
    appliance.succeed("nix-store --realize ${vimPath}", timeout=600)
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"vim did not run on v1 ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    print("OK: vim realized into the upper layer on v1")

    # ── Stage v2 + sysupdate → slot B ────────────────────────────────────────
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

    # ── Reboot → systemd-boot picks the highest-version UKI (abtest_2) ───────
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

    # ── O9: tool from the upper layer survives the slot swap ─────────────────
    out = appliance.succeed("${vimPath}/bin/vim --version")
    assert "VIM" in out, f"O9 FAIL: upper-layer tool lost across A/B swap ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    print("O9 OK: vim from the persistent upper still works after the swap")

    # ── O9: v2 lower paths visible through the merged store ──────────────────
    appliance.succeed("test -d /nix/store/${helloBasename}")
    print("O9 OK: v2 marker (hello) visible in the merged /nix/store")

    print("PASS: overlay upper survived A/B swap; v2 lower visible")
  '';
}

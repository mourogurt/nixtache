# Shared machinery for the OTA VM suites that boot REAL appliance images
# (rollback / noop / interrupted): a deployer test node (binary cache +
# sysupdate staging over nginx) and a driver-created appliance machine
# (OVMF → systemd-boot fallback → UKI, backdoor root shell on virtconsole
# from test-instrumentation.nix, static test-LAN address .3).
#
# The pattern is lifted from tests/overlay-nix-ab-swap-vm.nix; this module
# exists so the new suites do not each duplicate the QEMU/deployer wiring.
#
# `appliancePkgs` is the nixpkgs import the appliance systems evaluate with
# (CA — ab-image asserts it; see ab-fixture.nix). `pkgs` below stays the
# input-addressed tooling import.
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };

  # Throwaway binary-cache keypair: deployer signs, appliance trusts.
  cacheKey = pkgs.runCommand "ota-vm-cache-key" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export NIX_STATE_DIR=$TMPDIR/nix-state
    mkdir -p $out "$NIX_STATE_DIR"
    nix-store --generate-binary-cache-key ota-vm-local $out/private $out/public
  '';
  cachePub = builtins.readFile "${cacheKey}/public";
in
{
  inherit fixture lib pkgs;

  # Assert that a sysupdate run installed a new version, from the journal of
  # the boot that PERFORMED the update. Two invariants:
  #   - the stock update unit's canonical name is
  #     systemd-sysupdate-update.service (systemd-sysupdate.service is only an
  #     Alias); journald records messages under the canonical name and
  #     `journalctl -u` does not resolve aliases, so BOTH names are queried —
  #     a suite that overrides the unit (gating tests ship a
  #     systemd-sysupdate.service override) records under the alias name;
  #   - the evidence lives in the installing boot's journal: run this BEFORE
  #     any reboot leg (or in flows that never reboot) — after a reboot the
  #     previous boot's volatile journal may be gone.
  # Single-line command (no trailing newline/indent): suites interpolate it
  # inside a Python string literal — `node.succeed("${…}")` — and a raw
  # newline inside a double-quoted Python string is a syntax error that fails
  # the driver's script type-check at build time.
  assertSysupdateInstalled =
    "journalctl -u systemd-sysupdate-update.service -u systemd-sysupdate.service --no-pager | grep -i 'Successfully installed'";

  # The deployer node: nix-serve on :5000 (signed with the throwaway key)
  # + nginx on :80 serving the sysupdate staging dir.
  deployerNode = { extraDependencies ? [ ] }: { pkgs, ... }: {
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
    # staged 512M-class store images must fit on the root disk
    virtualisation.diskSize = 8192;
    # Suites generate validity records via the new CLI (nix path-info --json)
    system.extraDependencies = extraDependencies;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    networking.firewall.enable = false;
  };

  # An appliance config pulling from the deployer: staging over HTTP,
  # hermetic substituter, static address, driver plumbing. `extraModules`
  # lands on top of the real nixtache modules (the seam for broken-unit
  # knobs, tries overrides and overlay-nix).
  mkAppliance = { version, extraPackages ? [ ], extraModules ? [ ], storeSize ? "512M", signVerify ? false }:
    fixture.mkAppliance {
      inherit version;
      stagingPath = "http://deployer/ab-stage/abtest";
      # gptfdisk: every suite asserts slot labels via sgdisk.
      inherit storeSize signVerify;
      extraPackages = extraPackages ++ [ pkgs.gptfdisk ];
      extraModules = [
        (nixpkgs + "/nixos/modules/testing/test-instrumentation.nix")
        (nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
        ({ lib, ... }: {
          # mkForce: a plain assignment would CONCATENATE with the
          # nixpkgs default (cache.nixos.org) and every fetch pay DNS
          # timeouts on the hermetic test LAN.
          nix.settings.substituters = lib.mkForce [ "http://deployer:5000" ];
          nix.settings.trusted-public-keys = [ cachePub ];
          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth0.ipv4.addresses = [
            { address = "192.168.1.3"; prefixLength = 24; }
          ];
          networking.hosts."192.168.1.1" = [ "deployer" ];
          networking.firewall.enable = false;
        })
      ] ++ extraModules;
    };

  # Single-string start command for `create_machine(start_command=...)`;
  # each suite embeds it via Nix interpolation (`"${otaLib.startCommand v1Image}"`).
  # `-accel kvm -accel tcg`: KVM first, TCG fallback — on CI runners whose
  # build sandbox cannot open /dev/kvm (EPERM via the device cgroup), QEMU
  # falls back to TCG instead of dying before QMP handshake. The framework's
  # own declared-node VMs do the same fallback internally.
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
      "-netdev vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1"
      "-device virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03"
    ];
}

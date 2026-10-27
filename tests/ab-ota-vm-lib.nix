# Shared machinery for the VM suites that boot REAL appliance images
# outside the framework's declared nodes: a deployer test node (binary
# cache + sysupdate staging over nginx), a driver-created appliance
# machine (OVMF → systemd-boot fallback → UKI, backdoor root shell on
# virtconsole from test-instrumentation.nix, static test-LAN address .3),
# and the shared QEMU invocation base for created machines and pexpect
# drivers alike.
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

  # ---- Shared QEMU invocation for out-of-band appliance boots ------------
  # Every suite that boots a REAL appliance image outside the framework's
  # declared nodes — driver-created machines (create_machine) and pexpect
  # drivers alike — builds on these pieces, so the accelerator contract
  # lives in exactly one place:
  #   `-accel kvm -accel tcg` — KVM first, TCG fallback. On CI runners
  #   whose build sandbox cannot open /dev/kvm (EPERM via the device
  #   cgroup), QEMU falls back to TCG instead of dying before the QMP
  #   handshake; the framework's own declared-node VMs do the same
  #   fallback internally.
  accelArgs = [ "-accel" "kvm" "-accel" "tcg" ];

  # Created-machine base: q35 + `-cpu max` (the appliance userspace — zfs,
  # repart tooling — expects modern CPU features under the TCG fallback
  # too) and OVMF (the images' only boot path is UEFI: ESP fallback →
  # systemd-boot → UKI). Disks and NICs are the caller's concern — some
  # suites attach their image at runtime (python f-string disk path).
  machineArgs = { memory ? "3072", smp ? "4" }: [
    "${pkgs.qemu_test}/bin/qemu-kvm"
    "-machine"
    "q35"
    "-cpu"
    "max"
  ]
  ++ accelArgs
  ++ [
    "-bios" "${pkgs.OVMF.fd}/FV/OVMF.fd"
    "-m" memory
    "-smp" smp
  ];

  # The test-LAN netdev every created machine joins (vlan 1, static .3) so
  # the deployer node can reach it; $QEMU_VDE_SOCKET_1 is expanded by the
  # test driver when the start_command runs.
  vdeNetArgs = [
    "-netdev" "vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1"
    "-device" "virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03"
  ];
in
{
  inherit fixture lib pkgs machineArgs vdeNetArgs;

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

  # The common created-machine shape as a single-string start_command:
  # machine base + the image as a snapshot COW drive (the store image is
  # never mutated; in-test writes survive guest reboots) + the test LAN.
  # `extraArgs` carries suite deltas such as extra disks with serials.
  # Suites whose disk path is runtime knowledge compose machineArgs /
  # vdeNetArgs themselves instead.
  startCommand = { image, memory ? "3072", smp ? "4", extraArgs ? [ ] }:
    lib.concatStringsSep " " (
      machineArgs { inherit memory smp; }
      ++ [
        "-drive" "file=${image},id=drive1,if=none,werror=report,snapshot=on"
        "-device" "virtio-blk-pci,drive=drive1,bootindex=1"
      ]
      ++ vdeNetArgs
      ++ extraArgs
    );

  # pexpect-driver base: the same accelerator contract + OVMF, with serial
  # on stdio (pexpect reads the console), no display, no monitor mux. No
  # -cpu flag: under KVM that is host passthrough, under the TCG fallback
  # qemu64. Drivers append their image:
  #   args = base + ["-hda", image, "-snapshot"]
  pexpectQemuBin = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
  pexpectQemuArgs = { memory ? "2048", smp ? "4" }:
    [ "-machine" "q35" ]
    ++ accelArgs
    ++ [
      "-bios" "${pkgs.OVMF.fd}/FV/OVMF.fd"
      "-m" memory
      "-smp" smp
      "-display" "none"
      "-serial" "stdio"
      "-monitor" "none"
    ];

  # Render a list of QEMU args as a Python list literal for ${} embedding
  # into testScripts and pexpect drivers (the args carry no quotes).
  pyArgs = args: "[${lib.concatMapStringsSep ", " (s: ''"${s}"'') args}]";
}

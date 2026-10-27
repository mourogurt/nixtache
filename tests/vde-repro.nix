# Temporary diagnostic suite (fix-vmtests-run80): a create_machine QEMU with
# the vm-lib appliance shape (OVMF, q35, -cpu max, vde netdev) that CAPTURES
# QEMU's stderr to a file the testScript can print when the machine dies at
# QMP handshake — the driver swallows that output on this failure path.
{ nixpkgs, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Same shape as tests/ab-ota-vm-lib.nix startCommand (OVMF/q35/-cpu
  # max/vde/virtio-blk), minus the disk (OVMF idles at firmware without one),
  # wrapped to mirror QEMU stderr into $STATE/qemu.err.
  startCommand = pkgs.writeShellScript "start-vm" ''
    exec ${pkgs.qemu_test}/bin/qemu-kvm \
      -machine q35 \
      -cpu max \
      -accel kvm \
      -bios ${pkgs.OVMF.fd}/FV/OVMF.fd \
      -m 3072 -smp 4 \
      -drive file=/dev/null,id=drive1,if=none,format=raw \
      -device virtio-blk-pci,drive=drive1,bootindex=1 \
      -netdev vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1 \
      -device virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03 \
      2>qemu.err
  '';
in
pkgs.testers.runNixOSTest {
  name = "vde-create-machine-repro";
  globalTimeout = 300;
  nodes.deployer = { pkgs, ... }: {
    # defaults to virtualisation.vlans = [1] — the only declared node
  };
  testScript = ''
    deployer.start()
    deployer.wait_for_unit("multi-user.target")
    print("deployer up; creating appliance-shaped machine")
    import pathlib
    machine = create_machine(start_command="${startCommand}")
    try:
        machine.start()
        print("CREATED MACHINE QMP OK — no repro")
        machine.release()
    except Exception as e:
        print(f"CREATED MACHINE FAILED: {e}")
        err = pathlib.Path(machine.state_dir) / "qemu.err"
        print("=== qemu.err ===")
        print(err.read_text() if err.exists() else "(no qemu.err — QEMU never exec'd)")
        raise
  '';
}

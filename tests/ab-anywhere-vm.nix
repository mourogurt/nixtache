# ab-anywhere-vm — the FULL OTA lifecycle in ONE runNixOSTest (the "most
# complete" direct-deploy scenario):
#
#   given:  a deployer node carrying nixtache's deploy action, and a target
#           node WITHOUT nixtache — a plain NixOS VM with a bare second disk;
#   1. INSTALL: the deployer runs REAL `pkgs.nixos-anywhere --flake …` against
#      the target: kexec into a nixos-images-style installer → disko A/B
#      layout → closure copy → nixos-install → reboot. The installed system
#      is a real consumer config (tests/ab-anywhere-install.nix): nixtache
#      deploy-target + ab-image modules, disko A/B slots, ESP + UKI boot,
#      systemd-sysupdate, signature verification ON (publicKeyFile set →
#      Transfer.Verify=yes).
#   2. BOOT: the test then boots the installed disk in a FRESH QEMU with OVMF
#      (UEFI fallback → systemd-boot → UKI — the only boot path on the disk).
#      This is the mechanism nixos-anywhere's own test suite uses for the
#      post-install boot (tests/from-nixos.nix: create_machine on the same
#      qcow2); here the created machine additionally joins the vde test LAN
#      (vlan 1, nodeNumber 3 → 192.168.1.3) so the deployer can reach it.
#   3. UPDATE: the deployer stages a v2 sysupdate-package through the REAL
#      .forgejo/actions/deploy-target/action.yml run text (extracted at build
#      time, like tests/ab-deploy-e2e.nix; the only stub is fake-nix for
#      `nix flake show`/`nix build`), GPG-signs the manifest with the fixture
#      key, and SSH-triggers systemd-sysupdate on the installed machine.
#      sysupdate pulls v2 over HTTP, verifies the OpenPGP signature
#      (Verify=yes), writes slot B and relabels it nix-store_2.
#
# Assertions: the installed v1 system boots from the installed disk (UKI on
# the ESP); nix-store_2 GPT label appears; slot B contains the v2 marker
# (hello); slot A (v1) is intact; the target's transfers carry Verify=yes
# and the staged manifest was signed (positive control — negative cases live
# in ab-deploy-verify-vm).
#
# Hermeticity: the VMs have no internet. Everything the deployer-side
# `nixos-anywhere --flake` evaluation + `nix build` touches is pre-built on
# the host and registered in the deployer's nix DB via
# system.extraDependencies, so every in-VM `nix build` is a store no-op. The
# generated install flake (/etc/ab-install-flake) uses path: inputs pointing
# at the same store paths (offline-friendly), and the install config pins the
# sourceInfo-derived version fields, so in-VM evaluation hash-matches the
# pre-builds.
#
# Known simplifications vs. a bare-metal runbook:
#   - The running v1 system keeps /nix/store on the ext4 root; the A/B slots
#     are out-of-band update partitions (nixos-anywhere installs a closure —
#     it cannot dd raw image slots; the sysupdate slot flow itself is fully
#     real). Documented in tests/ab-anywhere-install.nix.
#   - The test does not reboot INTO slot B (that would need a second OVMF
#     boot + bless cycle; tests/ab-vm.nix covers UKI boot counting).
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };

  # Pinned external sources, fetched at eval time on the host (which has
  # internet); the VMs only ever see them as store paths.
  diskoSrc = pkgs.fetchFromGitHub {
    owner = "nix-community";
    repo = "disko";
    rev = "ff8702b4de27f72b4c78573dfb89ec74e36abdf1";
    hash = "sha256-RxWs5ND31KzTG7wvMM+PMfUjyNpmIEr999lqNARaM5o=";
  };
  nixosImages = pkgs.fetchFromGitHub {
    owner = "nix-community";
    repo = "nixos-images";
    rev = "b1ad9c218b7bab0a5165d66152fda1e967bc9b93";
    hash = "sha256-CkLQW9XvHD9imDkt4sau/89u2AeVkyzdADDK0QU7yHc=";
  };

  # The system nixos-anywhere installs (v1). ONE definition shared by the host
  # pre-build and the deployer VM's flake evaluation — see the file header of
  # tests/ab-anywhere-install.nix.
  installConfig = import ./ab-anywhere-install.nix {
    inherit nixpkgs system;
    nixtachePath = self;
    nixtacheModules = self.nixosModules;
    disko = diskoSrc;
  };
  installToplevel = installConfig.config.system.build.toplevel;
  installDiskoScript = installConfig.config.system.build.diskoScript;
  v1SysupdatePkg = installConfig.config.system.build.sysupdate-package;
  ukiFile = installConfig.config.system.boot.loader.ukiFile;

  # v2 — the OTA update payload (adds pkgs.hello as the content marker).
  # Placeholder version "0": the deploy action assigns the runtime version
  # (NIXTACHE_AB_VERSION=2 → image-version file → build → staged filenames),
  # exactly like CI — the fake-nix build stub enforces that contract.
  v2Config = fixture.mkAppliance {
    version = "0";
    signVerify = false;
    dataPartition = false;
    stagingPath = "http://deployer/ab-stage/abanywhere";
    storeSize = "1G";
    extraPackages = [ pkgs.hello ];
  };
  v2SysupdatePkg = v2Config.config.system.build.sysupdate-package;

  # kexec installer tarball: nixos-images' kexec-installer module built
  # against OUR nixpkgs (shared/cached closure). The default kernel package
  # set keeps the build cheap (it is what every nixosTest node already runs);
  # ZFS is unneeded for the ext4/vfat disko layout.
  kexecTarball =
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        (nixosImages + "/nix/kexec-installer/module.nix")
        (nixosImages + "/nix/noninteractive.nix")
        (
          { lib, pkgs, ... }:
          {
            system.kexec-installer.name = "nixos-kexec-installer-noninteractive";
            boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
            boot.supportedFilesystems.zfs = lib.mkForce false;
          }
        )
      ];
    }).config.system.build.kexecInstallerTarball;
  kexecTarballFile = pkgs.runCommand "nixos-kexec-installer-noninteractive.tar.gz" { } ''
    cp ${kexecTarball}/*.tar.gz $out
  '';

  # ESP content for the installed disk — exactly the files ab-image's repart
  # ESP contents carry (systemd-boot UEFI fallback + the UKI + loader.conf),
  # delivered via nixos-anywhere --extra-files because the appliance enables
  # no installable boot loader (image targets get their ESP from repart).
  espFiles = pkgs.runCommand "abanywhere-esp-files" { } ''
    mkdir -p $out/boot/EFI/BOOT $out/boot/EFI/Linux $out/boot/loader
    cp ${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi \
       $out/boot/EFI/BOOT/BOOT${lib.toUpper pkgs.stdenv.hostPlatform.efiArch}.EFI
    cp ${installConfig.config.system.build.uki}/${ukiFile} $out/boot/EFI/Linux/${ukiFile}
    printf 'timeout 0\n' > $out/boot/loader/loader.conf
  '';

  # Throwaway SSH keypair authorizing root logins for the nixos-anywhere run
  # itself (distinct from the fixture deploy key, which authorizes the
  # nixos-deploy user on the INSTALLED system for the sysupdate trigger).
  installKey = pkgs.runCommand "abanywhere-install-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p $out
    ssh-keygen -t ed25519 -N "" -C abanywhere-install -f $out/id_ed25519
  '';

  # The flake the deployer VM evaluates. path: inputs pointing at store paths
  # resolve fully offline (used directly, no fetch). The sourceInfo skew they
  # introduce is neutralised in the install config (pinned
  # system.nixos.versionSuffix/revision), so in-VM evaluation hash-matches the
  # host pre-builds and every in-VM `nix build` is a store no-op. The
  # nixtache subtree the config needs is vendored into the flake directory —
  # pure in-VM flake evaluation then sees only flake-local files.
  installFlake = pkgs.runCommand "ab-install-flake" { } ''
    mkdir -p $out/modules $out/tests
    cp -r ${self}/modules/deploy-target $out/modules/
    cp -r ${self}/modules/ab-image $out/modules/
    cp ${self}/tests/ab-fixture.nix $out/tests/
    cp ${self}/tests/ab-anywhere-install.nix $out/tests/
    cat > $out/flake.nix <<'FLAKE_EOF'
    {
      description = "ab-anywhere-vm install flake (generated by the test)";
      inputs.nixpkgs.url = "path:${pkgs.path}";
      inputs.disko.url = "path:${diskoSrc}";
      inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
      outputs = { nixpkgs, disko, ... }: {
        nixosConfigurations.abanywhere = import ./tests/ab-anywhere-install.nix {
          inherit nixpkgs disko;
          nixtachePath = ./.;
          nixtacheModules = {
            deploy-target = import ./modules/deploy-target;
            ab-image = import ./modules/ab-image;
          };
        };
      };
    }
    FLAKE_EOF
  '';

  # The raw action.yml text — embedded into the Python test driver so it can
  # assert on the content (single-source verification).
  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;

  # Extract the composite step's `run:` text at BUILD TIME — the SINGLE source
  # of the deploy logic (see tests/ab-deploy-e2e.nix for the rationale).
  actionRunScript = pkgs.runCommand "deploy-action-from-yml" {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyyaml ])) ];
  } ''
    python3 <<PYEOF
    import yaml
    with open("${actionYmlFile}") as f:
        a = yaml.safe_load(f)
    run = next(s["run"] for s in a["runs"]["steps"] if "run" in s)
    with open("$out", "w") as f:
        f.write("#!/bin/bash\n")
        f.write(run)
    PYEOF
    chmod +x "$out"
  '';

  # Fake `nix` wrapper — intercepts only `nix flake show` + `nix build` (the
  # deployer VM has no internet for real flake evaluation of the DEPLOYED
  # flake); everything else in the action runs verbatim. Same contract as
  # tests/ab-deploy-e2e.nix: the build stub requires the action to have
  # written the runtime version into `image-version` first, then stamps the
  # staged artifacts abtest_<runtime-version>.* — what the real build does
  # via ab-image.imageVersionFile. The remount is needed because NixOS stage 2
  # bind-remounts /nix/store read-only (boot.nixStoreMountOpts) — only the
  # nix-daemon's namespace sees it rw.
  fakeNix = pkgs.writeShellScript "fake-nix" ''
    if [ "$1" = "flake" ] && [ "$2" = "show" ]; then
      echo '${builtins.toJSON { nixosConfigurations.abanywhere = { }; }}'
      exit 0
    fi
    if [ "$1" = "build" ]; then
      if [ ! -f image-version ]; then
        echo "fake-nix: image-version missing — action must assign the runtime version BEFORE nix build" >&2
        exit 1
      fi
      ver=$(cat image-version)
      case "$ver" in
        1) src='${v1SysupdatePkg}' ;;
        *) src='${v2SysupdatePkg}' ;;
      esac
      mount -o remount,rw,bind /nix/store
      out="/nix/store/fake-build-abtest_$ver-sysupdate-package"
      rm -rf "$out"
      mkdir -p "$out"
      for f in "$src"/*; do
        base=$(basename "$f")
        cp "$f" "$out/''${base/abtest_0/abtest_$ver}"
      done
      echo "$out"
      exit 0
    fi
    exec ${pkgs.nix}/bin/nix "$@"
  '';

  # JSON deploy map — the same shape the nixtache runner module exports as
  # NIXTACHE_DEPLOY_TARGETS. The host is the installed machine's static IP
  # (it is created dynamically, so it has no driver-assigned hostname entry).
  deployTargets = builtins.toJSON {
    abanywhere = {
      method = "ab-image";
      sshUser = "nixos-deploy";
      host = "192.168.1.3";
      sshPort = "22";
      hasKey = true;
      enable = true;
      extraOptions = [ ];
    };
  };

  # Env file sourced before running the action script — the variables the
  # Forgejo runner would export, except GITHUB_REF and NIXTACHE_AB_VERSION
  # (set per-invocation by the test).
  deployEnvFile = pkgs.writeText "deploy-env" ''
    export GITHUB_EVENT_NAME=push
    export SANDBOX_OK=0
    export NIXTACHE_DEPLOY_TARGETS='${deployTargets}'
    export NIXTACHE_AB_STAGE=/var/lib/nixtache/ab-stage
    export NIXTACHE_RUNNER_HOST=deployer
    export CREDENTIALS_DIRECTORY=/run/credentials
    export PATH=/etc/fake-nix:$PATH
  '';
in
pkgs.testers.runNixOSTest {
  name = "ab-anywhere-vm";
  globalTimeout = 7200;

  nodes.deployer = { pkgs, lib, ... }: {
    services.nginx.enable = true;
    services.nginx.virtualHosts."deployer" = {
      locations."/ab-stage/" = {
        root = "/var/lib/nixtache";
        extraConfig = "autoindex on;";
      };
      # The v1 baseline store image, pulled by the installed machine to
      # populate slot A (the anywhere install itself puts the closure on the
      # ext4 root — slot A is filled out-of-band, like a factory flashed slot).
      locations."/v1-stage/" = {
        root = "/var/lib/nixtache";
        extraConfig = "autoindex on;";
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/nixtache/ab-stage 1777 root root -" ];
    virtualisation.diskSize = 8192;
    # Writable store (overlayfs upper on tmpfs) so in-VM nix instantiations and
    # the fake-nix "build outputs" land as new store paths.
    virtualisation.writableStore = true;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    environment.systemPackages = with pkgs; [ nixos-anywhere curl gnupg openssh jq ];
    environment.etc."deploy-action.sh".source = "${actionRunScript}";
    environment.etc."deploy-env.sh".source = "${deployEnvFile}";
    environment.etc."fake-nix/nix".source = "${fakeNix}";
    environment.etc."deploy-key".source = "${fixture.testDeployKey}/id_ed25519";
    environment.etc."signing-key".source = "${fixture.testSignKey}/priv.asc";
    environment.etc."install-key".source = "${installKey}/id_ed25519";
    environment.etc."ab-install-flake".source = "${installFlake}";
    environment.etc."ab-esp-files".source = "${espFiles}";
    environment.etc."nixos-anywhere/kexec-installer.tar.gz".source = "${kexecTarballFile}";
    # Everything the in-VM `nixos-anywhere --flake` build can reference —
    # registered in the guest nix DB at boot (register-nix-paths), so the
    # in-VM `nix build` of the same derivations is always a store no-op.
    system.extraDependencies = [
      installToplevel
      installDiskoScript
      v1SysupdatePkg
      v2SysupdatePkg
      espFiles
      kexecTarballFile
      fixture.testSignKey
      fixture.testDeployKey
      installKey
    ];
    services.openssh.enable = true;
    networking.firewall.enable = false;
  };

  # The bare machine: NO nixtache modules, a plain SSH-able NixOS VM whose
  # second disk (vdb, virtualisation.emptyDiskImages) is the install target.
  # 8 GB RAM: the kexec installer lives entirely in RAM (initrd + tmpfs
  # store). nixos-anywhere kexec's it into the installer environment itself.
  nodes.target = { pkgs, lib, ... }: {
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keyFiles = [ "${installKey}/id_ed25519.pub" ];
    virtualisation.memorySize = 8192;
    virtualisation.cores = 4;
    virtualisation.diskSize = 2048; # the node's own boot disk — never touched by the install
    virtualisation.emptyDiskImages = [ 8192 ]; # the bare disk nixos-anywhere installs to
    # get-facts.sh requirements on the pre-kexec system (setsid is in
    # util-linux, part of the base system path).
    environment.systemPackages = with pkgs; [ gnutar cpio ];
    networking.firewall.enable = false;
  };

  testScript = ''
    import yaml

    # ── Parse the REAL action.yml to verify the extracted script is genuine ──
    action = yaml.safe_load(${builtins.toJSON actionYml})
    run_text = next(s["run"] for s in action["runs"]["steps"] if "run" in s)
    assert "sysupdate-package" in run_text, "action.yml missing sysupdate-package build"
    assert "systemd-sysupdate" in run_text, "action.yml missing sysupdate trigger"
    assert "detach-sign" in run_text, "action.yml missing GPG signing"
    assert "NIXTACHE_AB_VERSION" in run_text, "action.yml missing runtime version assignment"
    print("OK: parsed action.yml (%d chars of run text)" % len(run_text))

    deployer.start()
    target.start()
    deployer.wait_for_unit("nginx.service")
    deployer.wait_for_unit("sshd.service")
    target.wait_for_unit("sshd.service")

    # ── Stage the v1 baseline store image (out-of-band "factory flash" of
    #    slot A; the install itself puts the v1 closure on the ext4 root) ────
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/v1-stage && "
      "cp ${v1SysupdatePkg}/* /var/lib/nixtache/v1-stage/"
    )

    # ── Install credentials + a writable copy of the install flake (nix needs
    #    to materialise flake.lock next to flake.nix; /etc is store-linked) ──
    deployer.succeed(
      "install -D -m600 /etc/install-key /root/.ssh/install_key && "
      "cp -rL /etc/ab-install-flake /tmp/install-flake && "
      "chmod -R u+w /tmp/install-flake"
    )

    # ── INSTALL: real nixos-anywhere — kexec → disko (A/B layout) → install →
    #    reboot. --flake + buildOn=local: the deployer builds diskoScript +
    #    toplevel from the install flake (store no-ops, see header), kexecs
    #    the target into the installer env, partitions /dev/vdb, copies the
    #    closure + the ESP extra-files, runs nixos-install, then reboots the
    #    target (its own boot disk is untouched, so it comes back as before).
    #    Backgrounded via nohup: run synchronously (deployer.succeed) the
    #    install stalls — nixos-anywhere's ssh sessions inherit the backdoor
    #    console as stdin and the kexec phase never completes; nohup gives it
    #    /dev/null stdin and the whole flow runs through.
    deployer.succeed(
      "nohup bash -c 'nixos-anywhere "
      "-i /root/.ssh/install_key "
      "--debug "
      "--kexec /etc/nixos-anywhere/kexec-installer.tar.gz "
      "--extra-files /etc/ab-esp-files "
      "--flake /tmp/install-flake#abanywhere "
      "--target-host root@target > /root/na.log 2>&1; echo $? > /root/na.exit' >/dev/null 2>&1 &"
    )
    import time
    for i in range(120):
        time.sleep(30)
        deployer.succeed("tail -2 /root/na.log >&2 || true")
        if deployer.succeed("test -f /root/na.exit && echo done || true").strip() == "done":
            break
    rc = deployer.succeed("cat /root/na.exit 2>/dev/null || echo missing").strip()
    if rc != "0":
        deployer.succeed("cat /root/na.log >&2 || true")
    assert rc == "0", f"nixos-anywhere failed with {rc}"
    print("OK: nixos-anywhere install finished (kexec → disko → install → reboot)")

    # nixos-anywhere returns as soon as the installer's sshd goes down, which
    # is a few seconds BEFORE the reboot actually kills the target's QEMU
    # (nodes run with -no-reboot). Wait for the process to exit — the
    # installed disk must be fully synced + its image lock released before it
    # is re-attached to the post-install machine below. crash() is the
    # fallback (install phase long completed by then).
    for i in range(36):
        if target.process is not None and target.process.poll() is not None:
            break
        time.sleep(5)
    try:
        target.crash()
    except Exception:
        pass
    try:
        target.wait_for_shutdown()
    except Exception:
        pass

    # ── BOOT the installed disk in a fresh QEMU (nixos-anywhere test-suite
    #    mechanism): OVMF UEFI boot of empty0.qcow2 — ESP fallback →
    #    systemd-boot → UKI is the ONLY boot path on the disk. The machine
    #    joins the vde test LAN (vlan 1) with nodeNumber 3 → 192.168.1.3.
    def create_installed_machine(oldmachine, **kwargs):
        start_command = [
            "${pkgs.qemu_test}/bin/qemu-kvm",
            "-machine", "q35",
            "-cpu", "max",
            "-accel", "kvm",
            "-bios", "${pkgs.OVMF.fd}/FV/OVMF.fd",
            "-m", "2048",
            "-smp", "2",
            "-drive", f"file={oldmachine.state_dir}/empty0.qcow2,id=drive1,if=none,werror=report",
            "-device", "virtio-blk-pci,drive=drive1,bootindex=1",
            "-netdev", "vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1",
            "-device", "virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03",
        ]
        machine = create_machine(start_command=" ".join(start_command), **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    installed = create_installed_machine(oldmachine=target, name="installed")
    try:
        installed.start()
    except Exception as e:
        # QEMU died before the QMP greeting — dump its console (stderr is
        # merged into stdout) to see why.
        qemu_out = b""
        if installed.process is not None:
            try:
                qemu_out = installed.process.stdout.read() or b""
            except Exception:
                pass
        print("installed QEMU failed to start:", e)
        print(qemu_out.decode(errors="replace")[-4000:])
        raise
    installed.wait_for_unit("multi-user.target")
    installed.wait_for_unit("sshd.service")

    # ── The installed v1 system: real disk boot, UKI on the ESP, signature
    #    verification configured, A/B slots laid out by disko ────────────────
    assert installed.succeed("cat /etc/image-version").strip() == "1"
    installed.succeed("ls /boot/EFI/Linux/ | grep -E 'abtest_1(\\+3)?\\.efi'")
    installed.succeed("test -f /etc/systemd/import-pubring.pgp")
    verify_modes = installed.succeed("grep -RhE '^Verify=' /etc/sysupdate.d/ | sort -u").strip()
    assert verify_modes == "Verify=yes", f"expected Verify=yes on all transfers, got: {verify_modes}"
    installed.succeed("sgdisk -p /dev/vda | grep nix-store_1")
    installed.succeed("sgdisk -p /dev/vda | grep _empty")
    print("OK: installed v1 system booted from disk (UKI), Verify=yes, slots nix-store_1 + _empty present")

    # ── Populate slot A with the staged v1 store (the "current" system) ──────
    installed.succeed(
      "curl -sf http://deployer/v1-stage/abtest_1.nix-store.raw | "
      "dd of=/dev/vda2 bs=4M conv=fsync",
      timeout=600
    )
    v1_hello = installed.succeed("unsquashfs -l /dev/vda2 | grep -c hello || true").strip()
    assert v1_hello == "0", f"v1 slot unexpectedly contains hello ({v1_hello})"
    print("OK: slot A populated with v1 store (no hello)")

    # ── UPDATE: real action.yml run — stage v2 (GPG-signed manifest) → SSH
    #    trigger of systemd-sysupdate on the installed machine ───────────────
    deployer.succeed(
      "mkdir -p /run/credentials && "
      "cp /etc/deploy-key /run/credentials/deploy_ssh_abanywhere && "
      "chmod 600 /run/credentials/deploy_ssh_abanywhere && "
      "cp /etc/signing-key /run/credentials/sysupdate_signing_key"
    )
    deployer.succeed("rm -f artifacts/deploy_abanywhere.log")
    # fake-nix on PATH intercepts `nix flake show` + `nix build`; everything
    # else — runtime version assignment, stage, sha256sum, gpg sign, ssh
    # trigger — runs verbatim from action.yml's run text.
    deployer.succeed(
      "cd /tmp && . /etc/deploy-env.sh && "
      "GITHUB_REF=refs/heads/main NIXTACHE_AB_VERSION=2 bash /etc/deploy-action.sh",
      timeout=600
    )
    deploy_log = deployer.succeed("cat artifacts/deploy_abanywhere.log")
    assert "assigning runtime version 2" in deploy_log, "v2 run did not assign runtime version 2: " + deploy_log[-500:]
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abanywhere/abtest_2.nix-store.raw")
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abanywhere/abtest_2.efi")
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abanywhere/SHA256SUMS.gpg")
    deployer.succeed("grep abtest_2 /var/lib/nixtache/ab-stage/abanywhere/SHA256SUMS")
    print("OK: v2 staged + manifest GPG-signed, sysupdate triggered over SSH")

    # ── Verify: sysupdate pulled v2 over HTTP, verified the signature, wrote
    #    slot B. The .efi transfer runs after the nix-store one, so its
    #    arrival means the whole service finished. ───────────────────────────
    installed.wait_until_succeeds(
      "test -f /boot/EFI/Linux/abtest_2.efi",
      timeout=300
    )
    # The _empty partition was relabelled nix-store_2 — the runtime version
    # travelled env → image-version → build → stage → GPT label.
    installed.succeed("sgdisk -p /dev/vda | grep nix-store_2")

    # ── Content proof: slot B holds v2 (hello), slot A still holds v1 ────────
    installed.succeed("unsquashfs -l /dev/vda3 | grep hello")
    v1_still = installed.succeed("unsquashfs -l /dev/vda2 | grep -c hello || true").strip()
    assert v1_still == "0", f"slot A was clobbered by the update ({v1_still})"
    installed.succeed("sgdisk -p /dev/vda | grep nix-store_1")  # rollback slot intact
    print("OK: slot B = v2 (hello present), slot A = v1 (no hello, intact)")

    # Diagnostic: final partition table + sysupdate journal tail.
    installed.succeed("sgdisk -p /dev/vda")
    installed.succeed("journalctl -u systemd-sysupdate.service --no-pager | tail -20 || true")

    print("PASS: nixos-anywhere install (kexec/disko/UKI) → signed OTA update → sysupdate wrote v2 to slot B on the installed disk")
  '';
}

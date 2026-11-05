# ab-ota-verify-vm — signature verification scenarios via runNixOSTest. Needs KVM (runNixOSTest carries
# requiredSystemFeatures = [ "kvm" "nixos-test" ] itself, like ab-provision-vm).
#
# Two nodes like ab-ota-e2e: a deployer (nginx staging + the REAL extracted
# action.yml + fake-nix) and a target (provision module owns the GPT + transfers
# on /dev/vdb). The difference: the target sets
# `ab.partitions.publicKeyFile = fixture.testSignKey/pubring.pgp`, so the module
# installs the pubring (/etc/systemd/import-pubring.pgp + /usr/lib symlink) and
# derives Transfer.Verify=yes — sysupdate REJECTS manifests whose SHA256SUMS.gpg
# doesn't verify against the test key.
#
# Run order (spec: C4 FIRST as positive control, then the negatives):
#   C4 ab-deploy-verify-correct:   ONE full action.yml run (NIXTACHE_AB_VERSION=2)
#                                  → signed staging accepted, nix-store_2 written.
#   C1 ab-deploy-verify-wrong-key: v3 staged MANUALLY (the action pipeline is
#                                  already proven by C4) but signed with the
#                                  SECOND throwaway keypair (fixture.testSignKey2)
#                                  → rejected.
#   C2 ab-deploy-verify-tampered:  v3 signed with the right key, then one byte of
#                                  the .nix-store.raw flipped → hash mismatch →
#                                  rejected.
#   C3 ab-deploy-verify-unsigned:  v3 signed, then SHA256SUMS.gpg removed →
#                                  rejected.
#
# Reset between cases: each negative case re-stages from scratch on the deployer
# (rm + cp + sha256sum + gpg). The target needs no reset. The key negative
# assertion is "no committed v3": no abtest_3+*.efi in the boot-target dir
# (nothing bootable was created), while the good nix-store_2 stays intact.
#
# Rejection model on the pinned systemd (261.1) — two distinct stages:
#  - MANIFEST-stage rejection (C1 wrong key, C3 unsigned): verification of
#    SHA256SUMS(.gpg) fails before any target is touched → no v3 state at
#    all, the unit exits 0 ("No update needed.").
#  - MID-INSTALL rejection (C2 tampered payload): the payload streams
#    directly into the inactive slot and its checksum is validated at stream
#    END — the mismatch aborts with the unit FAILED (exit 1) but a PARTIAL
#    v3 partition instance (label nix-store_3, never booted, never selected)
#    remains; the documented recovery is `systemd-sysupdate vacuum`, which
#    the suite exercises whenever a partial shows up.
# The nginx 404s for <file>.sha256.asc / <file>.sha256.gpg in the deployer
# log are systemd-pull probing per-file signature sidecars before falling
# back to SHA256SUMS.gpg — expected noise, not failures.
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };

  # v2 — the correctly-signed update (C4, full action run). v3 — the update the
  # negative cases stage manually + mutate. Both signed appliances so the
  # packaged SHA256SUMS matches what Verify=yes expects to check.
  v2Config = fixture.mkAppliance {
    version = "2";
    signVerify = true;
    dataPartition = false;
    stagingPath = "http://deployer/ab-stage/abtest-remote";
    storeSize = "512M";
    extraPackages = [ pkgs.hello ];
  };
  v2SysupdatePkg = v2Config.config.system.build.sysupdate-package;

  v3Config = fixture.mkAppliance {
    version = "3";
    signVerify = true;
    dataPartition = false;
    stagingPath = "http://deployer/ab-stage/abtest-remote";
    storeSize = "512M";
  };
  v3SysupdatePkg = v3Config.config.system.build.sysupdate-package;

  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;

  # Extract the composite step's `run:` text at BUILD TIME (same pattern as
  # ab-ota-e2e): the test executes the REAL staging/signing/SSH logic.
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

  # Same fake-nix contract as ab-ota-e2e: intercepts `flake show` / `build`,
  # requires the runtime `image-version` file (proving the action assigns the
  # version BEFORE the build). The build stub echoes the PREBUILT v2 package
  # (already in the deployer's store via extraDependencies; its artifacts are
  # already named abtest_2.*, matching NIXTACHE_AB_VERSION=2) — no store writes
  # (the VM's /nix/store overlay is remounted ro after boot).
  fakeNix = pkgs.writeShellScript "fake-nix" ''
    if [ "$1" = "flake" ] && [ "$2" = "show" ]; then
      echo '${builtins.toJSON { nixosConfigurations.abtest-remote = { }; }}'
      exit 0
    fi
    if [ "$1" = "build" ]; then
      if [ ! -f image-version ]; then
        echo "fake-nix: image-version missing — action must assign the runtime version BEFORE nix build" >&2
        exit 1
      fi
      # The action greps for /^\/nix\/store\// and checks -d "$img".
      echo '${v2SysupdatePkg}'
      exit 0
    fi
    exec ${pkgs.nix}/bin/nix "$@"
  '';

  deployTargets = builtins.toJSON {
    abtest-remote = {
      method = "ab-image";
      sshUser = "nixos-deploy";
      host = "target";
      sshPort = "22";
      hasKey = true;
      enable = true;
      extraOptions = [ ];
    };
  };

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
  name = "ab-ota-verify-vm";

  nodes.deployer = { pkgs, lib, ... }: {
    services.nginx.enable = true;
    services.nginx.virtualHosts."deployer" = {
      locations."/ab-stage/" = {
        root = "/var/lib/nixtache";
        extraConfig = "autoindex on;";
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/nixtache/ab-stage 1777 root root -" ];
    virtualisation.diskSize = 4096;
    # Writable store (overlayfs upper on tmpfs) so the fake-nix build stub can
    # materialise runtime-version-stamped "build outputs" as new store paths.
    virtualisation.writableStore = true;
    virtualisation.memorySize = 4096;
    environment.systemPackages = with pkgs; [ curl gnupg openssh jq ];
    environment.etc."deploy-action.sh".source = "${actionRunScript}";
    environment.etc."deploy-env.sh".source = "${deployEnvFile}";
    environment.etc."fake-nix/nix".source = "${fakeNix}";
    environment.etc."deploy-key".source = "${fixture.testDeployKey}/id_ed25519";
    environment.etc."signing-key".source = "${fixture.testSignKey}/priv.asc";
    # The WRONG key for C1 (its pubring is NOT installed on the target).
    environment.etc."signing-key2".source = "${fixture.testSignKey2}/priv.asc";
    system.extraDependencies = [ v2SysupdatePkg v3SysupdatePkg ];
    services.openssh.enable = true;
    networking.firewall.enable = false;
  };

  nodes.target = { pkgs, lib, config, ... }: {
    imports = [ self.nixosModules.deploy-target ];
    services.openssh.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;
    virtualisation.emptyDiskImages = [ 2048 ];
    # `systemd-sysupdate update --reboot` (the remote A/B trigger) reads
    # IMAGE_VERSION from os-release to assess the booted version — a
    # plain VM has none and sysupdate exits 1 silently. Mirror the
    # appliance baseline (slot A = version 1).
    system.image.id = "abtest";
    system.image.version = "1";

    services.nixtache.deploy-target = {
      enable = true;
      ab.enable = true;
      ab.gating = false;
      ab.partitions = {
        enable = true;
        slotSize = "512M";
        autoInit = true;
        imageId = "abtest";
        source = "http://deployer/ab-stage/abtest-remote";
        bootTarget = "/var/lib/nixtache/ab-slots/";
        # Verify=yes: the pubring matching the deployer's signing key. The
        # provision module installs it and derives Transfer.Verify=yes.
        publicKeyFile = "${fixture.testSignKey}/pubring.pgp";
        slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
        slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
      };
      deployUser = {
        name = "nixos-deploy";
        authorizedKey = fixture.deployKeyPub;
        autoProvision = true;
      };
    };

    systemd.tmpfiles.rules = [ "d /var/lib/nixtache/ab-slots 0755 root root -" ];
    environment.systemPackages = with pkgs; [
      util-linux
      gptfdisk
      squashfsTools
      curl
      # Expose systemd-sysupdate in PATH: the binary lives in systemd's
      # private lib dir, and the C2 recovery step below runs
      # `systemd-sysupdate vacuum` as a bare command (the appliance suites
      # get the same exposure via the fixture's abtest-systemd-aux-bins).
      (pkgs.runCommand "abtest-sysupdate-bin" { } ''
        mkdir -p $out/bin
        ln -s ${config.systemd.package}/lib/systemd/systemd-sysupdate $out/bin/
      '')
    ];
    networking.firewall.enable = false;
  };

  testScript = ''
    stage = "/var/lib/nixtache/ab-stage/abtest-remote"
    slots = "/var/lib/nixtache/ab-slots"

    deployer.start()
    target.start()
    deployer.wait_for_unit("nginx.service")
    target.wait_for_unit("sshd.service")
    target.wait_for_unit("nixtache-ab-provision.service")
    target.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    target.succeed("sgdisk -p /dev/vdb | grep _empty")
    # Verify=yes wired: pubring installed + transfer config carries it.
    target.succeed("test -f /etc/systemd/import-pubring.pgp")
    target.succeed("grep -Rh '^Verify=yes' /etc/sysupdate.d/")
    print("OK: provision laid out the GPT; Transfer.Verify=yes + pubring present")

    deployer.succeed(
      "mkdir -p /run/credentials && "
      "cp /etc/deploy-key /run/credentials/deploy_ssh_abtest-remote && "
      "chmod 600 /run/credentials/deploy_ssh_abtest-remote && "
      "cp /etc/signing-key /run/credentials/sysupdate_signing_key"
    )

    # -- C4 (positive control, FIRST): full action run, correctly signed -----
    # The action's trigger starts the target-side nixtache-ab-update unit
    # (update to completion, then the reboot assessment); with v2 (2) newer
    # than the booted baseline (1) the target REALLY reboots — see the
    # reboot handling after the .efi wait below.
    deployer.succeed(
      "cd /tmp && . /etc/deploy-env.sh && "
      "GITHUB_REF=refs/heads/main NIXTACHE_AB_VERSION=2 bash /etc/deploy-action.sh",
      timeout=300
    )
    deployer.succeed(f"test -f {stage}/abtest_2.nix-store.raw")
    deployer.succeed(f"test -f {stage}/SHA256SUMS.gpg")
    try:
        target.wait_until_succeeds(f"test -f {slots}/abtest_2+*.efi", timeout=300)
    except BrokenPipeError:
        # The reboot leg follows the .efi within seconds; a poll iteration
        # can straddle QEMU's exit — the exit itself is expected here.
        pass
    # The reboot leg restarts the node; declared test nodes run QEMU with
    # -no-reboot, so the reboot manifests as QEMU exiting — wait for the
    # exit and boot the node again (same disks: the fresh boot still runs
    # the v1 baseline system; the slots live on /dev/vdb, untouched).
    target.wait_for_shutdown()
    target.start()
    target.wait_for_unit("multi-user.target")
    target.succeed(f"test -f {slots}/abtest_2+*.efi")
    target.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
    target.succeed("unsquashfs -l /dev/vdb2 | grep hello")
    print("C4 OK: correctly-signed v2 accepted — nix-store_2 written, abtest_2+*.efi installed")

    def stage_v3(sign_key):
        """Manual staging of v3 (the action pipeline is proven by C4): reset the
        staging dir, copy the v3 package, regenerate SHA256SUMS, detach-sign
        with the given key (mirrors the action's gpg invocation)."""
        deployer.succeed(f"rm -rf {stage} && mkdir -p {stage}")
        deployer.succeed(f"cp ${v3SysupdatePkg}/* {stage}/")
        deployer.succeed(
          f"cd {stage} && sha256sum *.raw *.efi *.lower-db > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS"
        )
        deployer.succeed(
          f"export GNUPGHOME=$(mktemp -d) && "
          f"gpg --batch --import {sign_key} 2>/dev/null && "
          f"cd {stage} && gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS"
        )

    def attempt_v3(case):
        """Trigger sysupdate on the target against the (mutated) v3 staging
        and assert the update is REJECTED: nothing bootable appears, and the
        good v2 slot survives — including through the vacuum that heals a
        mid-install partial. Records the unit's exit status (manifest-stage
        rejections exit 0, mid-install ones fail the unit)."""
        # --wait: the upstream unit is Type=simple, so a plain start returns
        # at fork — without --wait the journal grep below would race the
        # still-running update.
        status, out = target.execute("systemctl start --wait systemd-sysupdate.service", timeout=300)
        print(f"{case}: systemd-sysupdate exit status = {status} ({'failed unit' if status != 0 else 'success-but-rejected'})")
        # Key assertion: no bootable v3 — the .efi transfer never completes
        # for a rejected update set.
        target.fail(f"test -f {slots}/abtest_3+*.efi")
        # A mid-install rejection (C2) leaves a PARTIAL nix-store_3 instance
        # — never booted; vacuum it and prove it goes away (the documented
        # recovery). Manifest-stage rejections (C1/C3) leave no v3 at all.
        has_partial = target.succeed(
          "sgdisk -p /dev/vdb | grep -c nix-store_3 || true"
        ).strip() != "0"
        if has_partial:
            target.succeed("systemd-sysupdate vacuum", timeout=120)
            target.fail("sgdisk -p /dev/vdb | grep nix-store_3")
        # The good version survives the rejected update (and the vacuum).
        target.succeed("sgdisk -p /dev/vdb | grep nix-store_2")
        target.succeed(f"test -f {slots}/abtest_2+*.efi")
        # Journal of THIS run shows the rejection (tail = latest attempt).
        # Query BOTH names: on current systemd the update unit's canonical
        # name is systemd-sysupdate-update.service (the plain name is an
        # alias) and `journalctl -u` does not resolve aliases.
        target.succeed(
          "journalctl -u systemd-sysupdate-update.service -u systemd-sysupdate.service --no-pager -n 40 | "
          "grep -iE 'verify|signature|checksum|hash|sha256|gpg'"
        )

    # -- C1: signed with the WRONG key (testSignKey2) → rejected ------------
    stage_v3("/etc/signing-key2")
    attempt_v3("C1")
    print("C1 OK: wrong-key signature rejected — no v3 committed")

    # -- C2: right key, then one byte of the payload flipped → hash mismatch --
    stage_v3("/etc/signing-key")
    deployer.succeed(f"printf 'x' | dd of={stage}/abtest_3.nix-store.raw bs=1 seek=1024 conv=notrunc")
    attempt_v3("C2")
    print("C2 OK: tampered payload rejected — no v3 committed")

    # -- C3: signature removed entirely → unsigned rejected ------------------
    stage_v3("/etc/signing-key")
    deployer.succeed(f"rm {stage}/SHA256SUMS.gpg")
    attempt_v3("C3")
    print("C3 OK: unsigned manifest rejected — no v3 committed")

    target.succeed("sgdisk -p /dev/vdb")
    print("PASS: C1-C4 — Verify=yes accepts the correct signature, rejects wrong-key/tampered/unsigned")
  '';
}

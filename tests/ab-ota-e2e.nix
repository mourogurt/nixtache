# ab-ota-e2e — full E2E deploy pipeline via runNixOSTest (Scenario A).
#
# Two requirements that distinguish this from a "stub" test:
#
# 1. RUNS THE REAL action.yml.  The deploy-target composite action's `run:`
#    text is extracted at build time (Python yaml parse of the actual file)
#    and written into the deployer VM as /etc/deploy-action.sh.  The test
#    sets the env vars the Forgejo runner would export and executes THAT
#    script — so any change to the staging / signing / SSH-trigger logic in
#    action.yml is exercised.  The only stub is a fake `nix` wrapper that
#    intercepts `nix flake show` and `nix build` (the VM has no internet for
#    real flake evaluation); everything else — cp, sha256sum, gpg sign, ssh
#    trigger — runs verbatim from the action source.
#
# 2. WRITES TO A REAL GPT PARTITION, LAID OUT BY THE PROVISION MODULE.  The
#    target VM has an extra disk (/dev/vdb via virtualisation.emptyDiskImages)
#    and enables `services.nixtache.deploy-target.ab.partitions` — the REAL
#    `nixtache-ab-provision.service` lays down the GPT (nix-store_1 + _empty,
#    autoInit) at boot, and the module-owned `10-nix-store` sysupdate transfer
#    (Type="partition", Target from the module; only the placeholder Source is
#    overridden to the deployer's HTTP staging).  sysupdate discovers the
#    _empty slot, downloads the v2 squashfs, writes it to the partition, and
#    relabels it nix-store_2.  The test asserts the GPT label changed, proving
#    a real on-disk partition update (not a regular-file copy).
#
# 3. RUNTIME VERSIONING (no declarative versions in the deploy path).  Both
#    appliances are built with the placeholder imageVersion "0".  The test
#    drives the action twice — NIXTACHE_AB_VERSION=1 (baseline, dry-activate)
#    and NIXTACHE_AB_VERSION=2 (the update, switch) — exactly like CI does.
#    The fake-nix build stub REQUIRES the repo's `image-version` file to
#    exist (the action writes it from NIXTACHE_AB_VERSION before invoking
#    `nix build`) and stamps the staged artifacts `abtest_<runtime-version>.*`
#    — simulating what the real build does via
#    `services.nixtache.ab-image.imageVersionFile`.  Assertions prove the
#    version flows env → image-version file → build → staged filenames → GPT
#    label.  A third run with NIXTACHE_AB_VERSION unset covers the calver
#    fallback (YYYYMMDDhhmmss).
#
# Pipeline: deployer (action.yml script → fake-nix build → stage → GPG sign
# → SSH trigger) → target (nixtache-ab-provision lays out /dev/vdb → test
# pulls the staged v1 store — NixOS WITHOUT hello — over HTTP and dd's it
# into slot A → systemd-sysupdate pulls v2 — WITH hello — over HTTP → writes
# slot B → relabels _empty → nix-store_2). Content assertions prove the
# update delivered new content (hello in slot B) and left the rollback slot
# intact (no hello in slot A).
{ nixpkgs, self, system ? "x86_64-linux", variant ? { } }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };

  # Compression-matrix knobs. Defaults reproduce the base variant
  # (squashfs + zstd); the flake registers
  # erofs / tool-default-compression / percent-slotSize variants as separate
  # vmTests keys.
  vCfg = {
    storeFs = "squashfs";
    storeCompression = "zstd";
    storeCompressionLevel = null;
    slotSize = "512M";
  } // variant;
  # The IMAGE store size must stay absolute (repart percents are relative to
  # the build-time image disk, not the target disk); only the TARGET-side
  # partitions.slotSize may be a percent (resolved against /dev/vdb).
  imageStoreSize = if lib.hasSuffix "%" vCfg.slotSize then "512M" else vCfg.slotSize;

  # FS-aware store-slot hello check (squashfs → unsquashfs; erofs → ro-mount
  # via the kernel erofs driver — unsquashfs cannot read erofs images, and the
  # erofs image root IS the store dir itself, no /nix/store prefix).
  helloInSlot = { part, count ? false }:
    if vCfg.storeFs == "erofs"
    then "modprobe erofs 2>/dev/null || true; mkdir -p /tmp/slot && "
      + "mount -t erofs -o ro /dev/vd${part} /tmp/slot && find /tmp/slot "
      + (if count then "| grep -c hello || true" else "| grep hello")
      + "; rc=$?; umount /tmp/slot; exit $rc"
    else "unsquashfs -l /dev/vd${part} | grep "
      + (if count then "-c hello || true" else "hello");

  # Both appliances use the PLACEHOLDER version "0": the deploy path never
  # sees a declarative version.  The runtime version (NIXTACHE_AB_VERSION →
  # image-version file → build) is what stamps `abtest_<v>.*` — see fakeNix.
  #
  # v1 — the CURRENT system on the target (baseline, no hello).  Its staged
  # nix-store.raw is pulled over HTTP by the target and dd'ed into slot A, so
  # the target starts with a genuinely populated v1 slot (not an empty
  # partition with a version label).
  v1Config = fixture.mkAppliance {
    version = "0";
    signVerify = false;
    dataPartition = false;
    stagingPath = "http://deployer/ab-stage/abtest-remote";
    storeSize = imageStoreSize;
    inherit (vCfg) storeFs storeCompression storeCompressionLevel;
  };
  v1SysupdatePkg = v1Config.config.system.build.sysupdate-package;

  # v2 — the UPDATE (adds pkgs.hello). Pre-built with a small storeSize so
  # the partition slots on the test disk stay manageable (512 MB each).
  v2Config = fixture.mkAppliance {
    version = "0";
    signVerify = false;
    dataPartition = false;
    stagingPath = "http://deployer/ab-stage/abtest-remote";
    storeSize = imageStoreSize;
    inherit (vCfg) storeFs storeCompression storeCompressionLevel;
    extraPackages = [ pkgs.hello ];
  };
  v2SysupdatePkg = v2Config.config.system.build.sysupdate-package;

  # The raw action.yml text — embedded into the Python test driver so it can
  # assert on the content (single-source verification).
  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;

  # Write the action.yml text to a store file so the build-time Python can
  # open it reliably (avoids path-resolution issues with toString in a
  # runCommand).  builtins.readFile already proves the file is accessible
  # at eval time — pkgs.writeText makes it available at build time too.
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;

  # Extract the composite step's `run:` text at BUILD TIME and write it as an
  # executable script.  This is the SINGLE source of the deploy logic: the
  # test runs THIS script, not a reimplementation.  If action.yml changes,
  # the extracted script changes too.
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

  # Fake `nix` wrapper — the deployer VM has no internet, so real
  # `nix flake show` / `nix build` can't resolve flake inputs.  This stub
  # returns pre-computed answers for exactly the two commands the action
  # uses, and delegates everything else to the real nix binary.
  #
  # The `build` stub enforces the RUNTIME VERSIONING contract: it fails
  # unless the action already wrote the repo's `image-version` file (i.e.
  # the version is assigned BEFORE the build), then stamps the staged
  # artifacts with that runtime version — exactly what the real build does
  # through `ab-image.imageVersionFile`.  Version "1" maps to the v1
  # (baseline) package, anything else to v2 (the update).
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
      ver=$(cat image-version)
      case "$ver" in
        1) src='${v1SysupdatePkg}' ;;
        *) src='${v2SysupdatePkg}' ;;
      esac
      # The deployer VM has a writable store at boot, but stage-2 activation
      # bind-remounts /nix/store read-only (boot.nixStoreMountOpts) — remount
      # the BIND rw so the stub can materialise a fresh "build output" store
      # path whose artifact names carry the RUNTIME version (what the real
      # build produces via ab-image.imageVersionFile).
      mount -o remount,rw,bind /nix/store
      out="/nix/store/fake-build-abtest_$ver-sysupdate-package"
      rm -rf "$out"
      mkdir -p "$out" || { echo "fake-nix: cannot create $out (store not writable)" >&2; exit 1; }
      for f in "$src"/*; do
        base=$(basename "$f")
        cp "$f" "$out/''${base/abtest_0/abtest_$ver}" || exit 1
      done
      echo "$out"
      exit 0
    fi
    exec ${pkgs.nix}/bin/nix "$@"
  '';

  # JSON deploy map — the same shape the nixtache runner module exports as
  # NIXTACHE_DEPLOY_TARGETS.  The action's main loop iterates over this.
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

  # Env file sourced before running the action script.  Sets the variables
  # the Forgejo runner would export — EXCEPT GITHUB_REF and
  # NIXTACHE_AB_VERSION, which each test run sets per-invocation (dry vs
  # switch mode, v1 vs v2 vs calver).
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
  name = "ab-ota-e2e";

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
    # The extracted action script + env + fake-nix, from the Nix store.
    environment.etc."deploy-action.sh".source = "${actionRunScript}";
    environment.etc."deploy-env.sh".source = "${deployEnvFile}";
    environment.etc."fake-nix/nix".source = "${fakeNix}";
    # Deploy SSH key + test signing key (copied into CREDENTIALS_DIRECTORY
    # by the test script before running the action).
    environment.etc."deploy-key".source = "${fixture.testDeployKey}/id_ed25519";
    environment.etc."signing-key".source = "${fixture.testSignKey}/priv.asc";
    # Pre-built sysupdate-packages (v1 baseline + v2 update) — forced into
    # the store so the fake-nix wrapper can stamp + echo their paths and the
    # action's `cp "$img"/*` works.
    system.extraDependencies = [ v1SysupdatePkg v2SysupdatePkg ];
    services.openssh.enable = true;
    networking.firewall.enable = false;
  };

  nodes.target = { pkgs, lib, ... }: {
    imports = [ self.nixosModules.deploy-target ];
    services.openssh.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;

    # Test-only: the action's remote ab trigger starts the -reboot variant
    # (write slot + REBOOT). A mid-test reboot would drop the driver's
    # connections — drop-in the unit to run the PLAIN update instead (the ""
    # element resets the upstream oneshot ExecStart list; the whole command
    # must be ONE element). Slot-write assertions stay; the reboot itself is
    # upstream behavior (same approach as ab-deploy-self-vm).
    systemd.services."systemd-sysupdate-reboot" = {
      description = "systemd-sysupdate reboot variant (TEST override: update without reboot)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ "" "${pkgs.systemd}/lib/systemd/systemd-sysupdate update" ];
      };
    };

    # Extra disk for A/B partition slots — appears as /dev/vdb.
    virtualisation.emptyDiskImages = [ 2048 ]; # 2 GB

    # The REAL provision module owns ALL of systemd.sysupdate on this target:
    # it enables sysupdate, lays out the GPT on /dev/vdb at boot
    # (nixtache-ab-provision.service: nix-store_1 + _empty), and derives BOTH
    # transfers — nix-store (Target from the slot config) and boot-image
    # (bootTarget: no ESP on this VM → a plain dir). The only deploy-specific
    # inputs are `source` (remote URL → url-file) and `imageId`.
    services.nixtache.deploy-target = {
      enable = true;
      ab.enable = true;
      ab.gating = false;
      ab.partitions = {
        enable = true;
        # Variant-controlled (A5: "25%" of the 2 GB test disk ≈ the 512M image).
        slotSize = vCfg.slotSize;
        autoInit = true;
        imageId = "abtest";
        source = "http://deployer/ab-stage/abtest-remote"; # remote deploy → url-file
        bootTarget = "/var/lib/nixtache/ab-slots/";        # no ESP on this VM
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
    environment.systemPackages = with pkgs; [ util-linux gptfdisk squashfsTools curl ];
    networking.firewall.enable = false;
  };

  testScript = ''
    import yaml
    import re

    # ── Parse the REAL action.yml to verify the extracted script is genuine ──
    action = yaml.safe_load(${builtins.toJSON actionYml})
    run_text = next(s["run"] for s in action["runs"]["steps"] if "run" in s)
    assert "sysupdate-package" in run_text, "action.yml missing sysupdate-package build"
    assert "systemd-sysupdate" in run_text, "action.yml missing sysupdate trigger"
    assert "detach-sign" in run_text, "action.yml missing GPG signing"
    assert "NIXTACHE_AB_VERSION" in run_text, "action.yml missing runtime version assignment"
    # Exactly one sysupdate-package build, and the image-version write must
    # precede it (runtime version flows into the build).
    assert run_text.count("config.system.build.sysupdate-package") == 1, \
        "action.yml must build the sysupdate-package exactly once (after assigning the version)"
    assert run_text.index('echo "$version" > image-version') < run_text.index("config.system.build.sysupdate-package"), \
        "image-version write must precede the sysupdate-package build"
    print("Q5 OK: parsed action.yml (%d chars of run text)" % len(run_text))

    # ── Boot both nodes ──────────────────────────────────────────────────────
    deployer.start()
    target.start()
    deployer.wait_for_unit("nginx.service")
    target.wait_for_unit("sshd.service")
    target.wait_for_unit("systemd-sysupdate.timer")
    target.wait_for_unit("nixtache-ab-provision.service")

    # ── Verify initial GPT partition state on /dev/vdb (laid out by the
    #    provision module: slot A + free slot B) ────────────────────────────
    target.succeed("sgdisk -p /dev/vdb | grep nix-store_1")
    target.succeed("sgdisk -p /dev/vdb | grep _empty")
    print("OK: provision module created nix-store_1 (v1 slot) + _empty (slot B) on /dev/vdb")

    # ── Set up credentials directory (deploy key + signing key) ──────────────
    deployer.succeed(
      "mkdir -p /run/credentials && "
      "cp /etc/deploy-key /run/credentials/deploy_ssh_abtest-remote && "
      "chmod 600 /run/credentials/deploy_ssh_abtest-remote && "
      "cp /etc/signing-key /run/credentials/sysupdate_signing_key"
    )

    def run_action(ref, ab_version):
        """Run the REAL action.yml script with the given git ref (mode) and
        NIXTACHE_AB_VERSION. Returns the per-target deploy log."""
        deployer.succeed("rm -f artifacts/deploy_abtest-remote.log")
        env = f"GITHUB_REF={ref}"
        if ab_version is not None:
            env += f" NIXTACHE_AB_VERSION={ab_version}"
        # fake-nix on PATH intercepts `nix flake show` + `nix build`;
        # everything else — RUNTIME VERSION assignment, stage, sha256sum,
        # gpg sign, ssh trigger — runs verbatim from action.yml's run text.
        deployer.succeed(
          f"cd /tmp && . /etc/deploy-env.sh && {env} bash /etc/deploy-action.sh",
          timeout=180
        )
        return deployer.succeed("cat artifacts/deploy_abtest-remote.log")

    # ── RUN 1: v1 baseline — NIXTACHE_AB_VERSION=1, dry-activate ────────────
    # (non-main ref → mode=dry-activate: build + stage + sign, no apply).
    log = run_action("refs/heads/staging", "1")
    assert "assigning runtime version 1" in log, "v1 run did not assign runtime version 1: " + log[-500:]
    assert deployer.succeed("cat /tmp/image-version").strip() == "1"
    # The build stamped the staged artifacts with the RUNTIME version (the
    # prebuilt package carries the placeholder version 0 — renamed by the
    # build step, like the real imageVersionFile flow).
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abtest-remote/abtest_1.nix-store.raw")
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abtest-remote/abtest_1+*.efi")
    deployer.succeed("grep abtest_1 /var/lib/nixtache/ab-stage/abtest-remote/SHA256SUMS")
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abtest-remote/SHA256SUMS.gpg")
    print("OK: RUN 1 — runtime version 1 → image-version file → staged abtest_1.* (signed, dry-activate)")

    # ── Populate slot A with the staged v1 store (the "current" system) ─────
    # v1 = NixOS WITHOUT hello; v2 (staged by RUN 2) = NixOS WITH hello.
    # The target pulls the staged raw over HTTP — the same channel sysupdate
    # uses — and dd's it into slot A.
    target.succeed(
      "curl -sf http://deployer/ab-stage/abtest-remote/abtest_1.nix-store.raw | "
      "dd of=/dev/vdb1 bs=4M conv=fsync",
      timeout=300
    )
    v1_hello = target.succeed("${helloInSlot { part = "b1"; count = true; }}").strip()
    assert v1_hello == "0", f"v1 slot unexpectedly contains hello ({v1_hello})"
    print("OK: slot A populated with v1 store (no hello)")

    # ── RUN 2: v2 update — NIXTACHE_AB_VERSION=2, switch (main) ─────────────
    log = run_action("refs/heads/main", "2")
    assert "assigning runtime version 2" in log, "v2 run did not assign runtime version 2: " + log[-500:]
    assert deployer.succeed("cat /tmp/image-version").strip() == "2"
    deployer.succeed("test -f /var/lib/nixtache/ab-stage/abtest-remote/abtest_2.nix-store.raw")
    deployer.succeed("grep abtest_2 /var/lib/nixtache/ab-stage/abtest-remote/SHA256SUMS")
    print("OK: RUN 2 — runtime version 2 → staged abtest_2.*, sysupdate triggered")

    # Diagnostic: show what was staged + the manifest.
    deployer.succeed("ls -la /var/lib/nixtache/ab-stage/abtest-remote/")
    deployer.succeed("cat /var/lib/nixtache/ab-stage/abtest-remote/SHA256SUMS")

    # ── Verify: sysupdate pulled v2 over HTTP → wrote to GPT partition ───────
    # sysupdate processes transfers sequentially (nix-store first, then
    # boot-image) and sets the partition label BEFORE downloading content.
    # So we must wait for the ENTIRE service to finish, not just poll the
    # label.  The action's SSH `systemctl start` is synchronous, but the
    # label is visible early — use wait_until_succeeds on the .efi (the last
    # transfer) to know sysupdate is truly done.
    target.wait_until_succeeds(
      "test -f /var/lib/nixtache/ab-slots/abtest_2+*.efi",
      timeout=180
    )
    # The _empty partition was relabelled to nix-store_2 — the runtime
    # version travelled env → image-version → build → stage → GPT label.
    target.succeed("sgdisk -p /dev/vdb | grep nix-store_2")

    # ── Content proof: slot B holds v2 (hello), slot A still holds v1 ────────
    target.succeed("${helloInSlot { part = "b2"; }}")
    v1_still = target.succeed("${helloInSlot { part = "b1"; count = true; }}").strip()
    assert v1_still == "0", f"slot A was clobbered by the update ({v1_still})"
    target.succeed("sgdisk -p /dev/vdb | grep nix-store_1")  # rollback slot intact
    print("OK: slot B = v2 (hello present), slot A = v1 (no hello, intact)")

    # ── RUN 3: calver fallback — NIXTACHE_AB_VERSION unset, dry-activate ────
    # Without the env override the action assigns a UTC calver
    # (YYYYMMDDhhmmss) — the production default. Dry mode: no apply, so the
    # deployed v2 state is untouched.
    log = run_action("refs/heads/staging", None)
    m = re.search(r"assigning runtime version (\d{14})", log)
    assert m, "calver fallback did not assign a 14-digit version: " + log[-500:]
    ver = m.group(1)
    ivf = deployer.succeed("cat /tmp/image-version").strip()
    assert ivf == ver, f"image-version file mismatch ({ivf} != {ver})"
    deployer.succeed(f"test -f /var/lib/nixtache/ab-stage/abtest-remote/abtest_{ver}.nix-store.raw")
    print("OK: RUN 3 — calver fallback assigned " + ver + " (staged abtest_" + ver + ".*)")

    # Diagnostic: show final partition table.
    target.succeed("sgdisk -p /dev/vdb")

    print("PASS: runtime-versioned action.yml → stage → sign → SSH → sysupdate wrote v2 to PARTITION on /dev/vdb")
  '';
}

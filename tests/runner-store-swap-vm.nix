# runner-store-swap-vm — R4 (formerly skipped in ab-runner-compat-vm): the
# runner's relocated store across a REAL appliance slot swap, on a real
# mkAppliance image with the runner container baked in.
#
# Runs the shipped world: the appliance image carries the lower store DB
# (ab-image; loaded at boot), so the clone seed enumerates the real host DB
# and the overlay mode opens it as `lower-store=local` (a daemon lower would
# self-reference — no system daemon exists in the appliance-mode container).
# The container is ordered after the host's loader oneshot so a post-swap
# start never enumerates a pre-merge DB. In the vmtests.yml CI matrix (both
# modes); the host-side nspawn bind-path guarantee is pinned by
# tests/runner.nix "appliance host (nix.enable=false)".
#
# Why: the runner host (the reference server) reboots under its own CI when
# it self-updates; after every swap the lower store the container's store was
# cloned/overlayed from is REPLACED. This suite pins that CI builds keep
# working across the swap in both store modes:
#
#   clone   — the post-swap re-clone is additive: the pre-swap build output
#             survives in /srv/nix/store and the NEW lower's content arrives
#             on top (hello marker baked only into v2).
#   overlay — the overlay remounts over the new lower; the upper's build
#             output stays visible; new builds keep working.
#
# The pinned nixpkgs' container machinery binds the host's /nix/var/nix/db +
# daemon-socket only when the HOST has nix enabled (nixos-containers.nix) —
# on the appliance (host nix.enable=false) those binds are skipped, which is
# what makes the container startable at all there. The suite proves the
# container starts and serves builds on BOTH boots.
#
# Signing is on (signVerify) — the runner host's pulls verify manifests.
# Needs KVM. Hermetic: the deployer node stages the signed v2 package; the
# build is a trivial derivation with substitute=false (no network).
{ nixpkgs, self, system ? "x86_64-linux", storeMode ? "clone" }:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system; };
  inherit (otaLib) fixture pkgs lib;

  helloBasename = baseNameOf pkgs.hello.outPath;

  mkRunnerAppliance = { version, extraPackages ? [ ] }:
    otaLib.mkAppliance {
      inherit version;
      signVerify = true;
      storeSize = "2G";
      extraPackages = extraPackages ++ [ pkgs.gptfdisk ];
      extraModules = [
        self.nixosModules.runner
        ({ lib, ... }: {
          networking.useDHCP = false;
          services.nginx.enable = true;
          services.nixtache.runner = {
            enable = true;
            forgejoUrl = "http://localhost:3000";
            cache = {
              enable = true;
              domain = "localhost";
              port = 5000;
            };
            instances.default = {
              uuid = "00000000-0000-4000-8000-000000000000";
              tokenFile = toString /dev/null;
            };
            secrets.cachePrivateKey = toString /dev/null;
            # The relocated store lives at /srv/nix (the persistent root).
            store.path = "/srv";
            store.mode = storeMode;
            # nspawn without CAP_SYS_ADMIN cannot run the nix sandbox; the
            # overlay mode needs the cap for the mount.
            enableSandbox = false;
            additionalCapabilities = lib.optional (storeMode == "overlay") "CAP_SYS_ADMIN";
          };
          # The cache vhost defaults to HTTPS+ACME; force plain HTTP in the VM
          # (mirrors tests/runner-store-mode-vm.nix).
          services.nginx.virtualHosts."localhost".forceSSL = lib.mkForce false;
          services.nginx.virtualHosts."localhost".enableACME = lib.mkForce false;
        })
      ];
    };

  v1 = mkRunnerAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = mkRunnerAppliance { version = "2"; extraPackages = [ pkgs.hello ]; };
  v2Pkg = v2.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "runner-store-swap-${storeMode}";
  globalTimeout = 7200;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ v2Pkg ]; };

  testScript = ''
    import shlex

    def create_runner_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand v1Image}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    # Run a command as root INSIDE the runner container. Returns stdout.
    def crun(inner):
        return appliance.succeed(
            "nixos-container run runner -- /bin/sh -c " + shlex.quote(inner)
        )

    # Build a trivial derivation through the relocated store's custom daemon
    # socket (in-container). Returns the last output line (the out path).
    def build_proof():
        builder = crun("readlink -f /bin/sh").strip()
        out = crun(
            "nix --extra-experimental-features nix-command "
            "build --no-link --print-out-paths "
            "--store unix:///srv/nix/var/nix/daemon-socket/socket "
            "--option sandbox false --option substitute false "
            "--option build-users-group \"\" "
            "--expr 'derivation { name = \"runner-swap-proof\"; "
            "system = \"${system}\"; builder = \"" + builder + "\"; "
            "args = [ \"-c\" \"echo ok > $out\" ]; }' 2>&1"
        ).strip().splitlines()[-1]
        assert "runner-swap-proof" in out, f"unexpected build output: {out!r}"
        return out

    deployer.start()
    deployer.wait_for_unit("nginx.service")

    appliance = create_runner_machine(name="appliance")
    appliance.start(allow_reboot=True)
    # The first boot's multi-user.target includes the runner container, whose
    # boot includes the clone seed (`nix-daemon-storage`: a full `nix copy
    # --all` of the appliance closure into /srv/nix, Nice=19, inside nested
    # QEMU). On real hardware this takes minutes; under QEMU the per-path
    # sqlite/fsync overhead makes it take much longer, so poll with progress
    # dumps (the seed's journal lives inside the container, invisible on the
    # host console) instead of a blind wait. Post-swap boots are fast (the
    # clone is additive, only the delta re-copies).
    import time
    deadline = time.time() + 14400
    while True:
        try:
            jobs = appliance.succeed("systemctl list-jobs --no-legend | head -5 || true")
            seed = appliance.succeed(
                "nixos-container run runner -- sh -c '"
                "systemctl is-active nix-daemon-storage; "
                "echo ---journal; "
                "journalctl -u nix-daemon-storage -n 15 --no-pager 2>&1 | tail -15; "
                "echo ---scratch; "
                "ls /run/nix-clone-state/db 2>&1 | head -3; "
                "exit 0'",
                timeout=90,
            )
            print(f"SEEDPOLL active={seed.strip().splitlines()[:20]} jobs={jobs.strip()[:200]}", flush=True)
            if "multi-user.target" not in jobs:
                break
        except Exception as e:
            print(f"SEEDPOLL transient: {e}", flush=True)
        if time.time() > deadline:
            raise Exception("appliance multi-user.target not reached within 14400s")
        time.sleep(120)
    appliance.wait_for_unit("multi-user.target", timeout=600)
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    # Bless v1 (boot-complete) so its remaining tries cannot outrank v2 later.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("OK: v1 appliance booted and blessed")

    # -- The runner container comes up on the appliance ----------------------
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet container@runner.service", timeout=600
    )
    appliance.wait_until_succeeds(
      "nixos-container run runner -- systemctl is-active nix-daemon-custom",
      timeout=600
    )
    print("OK: runner container + custom daemon up on the appliance")

    # -- A CI build through the relocated store works pre-swap ---------------
    try:
        proof_v1 = build_proof()
    except Exception:
        print("DIAG nix-daemon-custom journal:")
        print(crun("journalctl -u nix-daemon-custom -n 60 --no-pager 2>&1 || true"))
        print("DIAG pids:", crun("cat /sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.max /sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.current 2>&1 || true"))
        print("DIAG ps:", crun("ps aux 2>&1 | head -40 || true"))
        print("DIAG ps count:", crun("ps aux 2>&1 | wc -l || true"))
        print("DIAG host container pids:", appliance.succeed("cat /sys/fs/cgroup/machine.slice/container@runner.service/pids.current /sys/fs/cgroup/machine.slice/container@runner.service/pids.max 2>&1 || true"))
        raise
    print(f"OK: pre-swap build through the relocated store: {proof_v1}")

    # -- Stage v2 SIGNED → sysupdate → slot B → reboot -----------------------
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
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet container@runner.service", timeout=600
    )
    print("OK: v2 booted; runner container up post-swap")
  '' + (
    if storeMode == "clone" then ''
      # -- clone: the re-clone after the swap is additive --------------------
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-custom",
        timeout=900
      )
      # The pre-swap build output survived (old paths kept)...
      proof_out = crun("ls -d /srv/nix/store/*-runner-swap-proof")
      # ...and the re-clone pulled the NEW lower's content (hello, baked only
      # into v2's squashfs) into the clone.
      crun("ls -d /srv/nix/store/${helloBasename} >/dev/null")
      print("OK: clone is additive — old build output kept, new lower content arrived")
    '' else ''
      # -- overlay: remount over the new lower, upper intact -----------------
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-overlay-mount",
        timeout=600
      )
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-custom",
        timeout=600
      )
      # The pre-swap build output (upper, no lower refs) is still visible...
      crun("ls -d /srv/nix/store/*-runner-swap-proof >/dev/null")
      # ...and the NEW lower's hello is visible through the merged view.
      crun("ls -d /srv/nix/store/${helloBasename} >/dev/null")
      print("OK: overlay coherent post-swap — upper intact, new lower visible")
    ''
  ) + ''
    # -- A CI build works post-swap (both modes) -----------------------------
    proof_v2 = build_proof()
    print(f"OK: post-swap build through the relocated store: {proof_v2}")

    print("PASS: runner store (${storeMode}) serves CI builds across an OTA swap")
  '';
}

# runner-store-swap-vm — the runner's relocated store across a real
# appliance slot swap, on a real mkAppliance image with the container baked in.
#
# Runs the shipped world: the appliance image carries the lower store DB
# (ab-image; loaded at boot), so the clone seed enumerates the real host DB.
# Overlay mode opens the selected host's composite local-overlay lower through
# a dedicated read-only root outside the runner's relocated /nix. The container
# is ordered after the host's loader oneshot so a post-swap start never reads a
# pre-merge DB. In the vmtests.yml CI matrix (both modes); the host-side nspawn
# bind-path guarantee is pinned by tests/runner.nix.
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
# on the appliance (host nix.enable=false) those binds are skipped. The
# runner module therefore binds the host's lower-store DB into the container
# itself (read-only, ordered after the slot's lower-DB loader): the clone
# seed enumerates it and overlay mode's lower-store=local opens it. The suite
# proves the container starts and serves builds on BOTH boots.
#
# Signing is on (signVerify) — the runner host's pulls verify manifests.
# Needs KVM. Hermetic: the deployer node stages the signed v2 package; the
# build is a trivial derivation with substitute=false (no network).
{ nixpkgs, self, system ? "x86_64-linux", storeMode ? "clone", ephemeral ? false, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; } }:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) fixture pkgs lib;

  cascade = storeMode == "overlay";
  helloBasename = baseNameOf pkgs.hello.outPath;

  mkRunnerAppliance = { version, extraPackages ? [ ], brokenBoot ? false }:
    otaLib.mkAppliance {
      inherit version;
      signVerify = true;
      storeSize = "2G";
      extraPackages = extraPackages ++ [ pkgs.gptfdisk ];
      extraModules = [
        self.nixosModules.runner
      ] ++ [ self.nixosModules.overlay-nix ] ++ [
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
            store.path = "/srv";
            store.mode = storeMode;
            enableSandbox = false;
            additionalCapabilities = lib.optional cascade "CAP_SYS_ADMIN";
          };
          services.nixtache.overlay-nix = lib.mkIf cascade ({
            enable = true;
            upperOnUpdate = "reconcile";
          } // lib.optionalAttrs ephemeral {
            upperDir = "/tmp/nix-overlay/upper";
            workDir = "/tmp/nix-overlay/work";
          });
          services.nixtache.deploy-target = lib.mkIf (cascade && !ephemeral) {
            criticalUnits = [ "nixtache-runner-rollback-canary.service" ];
            healthCheckTimeout = lib.mkIf brokenBoot 20;
          };
          services.nixtache.ab-image.ukiTries = lib.mkIf brokenBoot 2;
          systemd.services.nixtache-runner-rollback-canary = lib.mkIf (cascade && !ephemeral) {
            wantedBy = [ "multi-user.target" ];
            after = [ "container@runner.service" ];
            requires = [ "container@runner.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            script = if brokenBoot then "exit 1" else ":";
          };
          fileSystems."/tmp/nix-overlay" = lib.mkIf ephemeral {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=755" ];
          };
          services.nginx.virtualHosts."localhost".forceSSL = lib.mkForce false;
          services.nginx.virtualHosts."localhost".enableACME = lib.mkForce false;
        })
      ];
    };

  v1 = mkRunnerAppliance { version = "1"; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = mkRunnerAppliance {
    version = "2";
    extraPackages = [ pkgs.hello ];
    brokenBoot = cascade && !ephemeral;
  };
  v2Pkg = v2.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "runner-store-swap-${storeMode}${lib.optionalString ephemeral "-ephemeral"}";
  globalTimeout = 7200;

  nodes.deployer = otaLib.deployerNode { extraDependencies = lib.optional (!ephemeral) v2Pkg; };

  testScript = ''
    import shlex

    CASCADE = ${if cascade then "True" else "False"}
    EPHEMERAL = ${if ephemeral then "True" else "False"}

    def create_runner_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    # Run a command as root INSIDE the runner container. Returns stdout.
    def crun(inner):
        return appliance.succeed(
            "nixos-container run runner -- /bin/sh -c " + shlex.quote(inner)
        )

    def cfail(inner):
        return appliance.fail(
            "nixos-container run runner -- /bin/sh -c " + shlex.quote(inner)
        )

    # Build a trivial derivation through the relocated store's custom daemon
    # socket (in-container). Returns the last output line (the out path).
    def build_proof(phase):
        builder = crun("readlink -f /bin/sh").strip()
        out = crun(
            "nix --extra-experimental-features nix-command "
            "build --no-link --print-out-paths "
            "--store unix:///srv/nix/var/nix/daemon-socket/socket "
            "--option sandbox false --option substitute false "
            "--expr 'derivation { name = \"runner-swap-proof-" + phase + "\"; "
            "system = \"${system}\"; builder = \"" + builder + "\"; "
            "args = [ \"-c\" \"echo " + phase + " > $out\" ]; }' 2>&1"
        ).strip().splitlines()[-1]
        assert "runner-swap-proof-" + phase in out, f"unexpected build output: {out!r}"
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
            if appliance.succeed("systemctl is-active multi-user.target || true").strip() == "active":
                break
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
    try:
        appliance.wait_until_succeeds(
          "nixos-container run runner -- systemctl is-active nix-daemon-custom",
          timeout=600
        )
    except Exception:
        print("DIAG custom daemon units:")
        print(crun("systemctl status nix-daemon-custom.service nix-daemon-custom.socket nix-daemon-overlay-mount.service --no-pager -l 2>&1 || true"))
        print("DIAG custom daemon journal:")
        print(crun("journalctl -u nix-daemon-custom.service -u nix-daemon-custom.socket -u nix-daemon-overlay-mount.service -n 100 --no-pager 2>&1 || true"))
        print("DIAG custom daemon paths:")
        print(crun("ls -ld /srv/nix /srv/nix/var /srv/nix/var/nix /srv/nix/var/nix/daemon-socket /srv/nix/var/nix/daemon-socket/socket 2>&1 || true"))
        raise
    print("OK: runner container + custom daemon up on the appliance")

    # -- A CI build through the relocated store works pre-swap ---------------
    crun("test ! -e /srv/nix/store/${helloBasename}")
    try:
        proof_v1 = build_proof("v1")
    except Exception:
        print("DIAG nix-daemon-custom journal:")
        print(crun("journalctl -u nix-daemon-custom -n 60 --no-pager 2>&1 || true"))
        print("DIAG pids:", crun("cat /sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.max /sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.current 2>&1 || true"))
        print("DIAG ps:", crun("ps aux 2>&1 | head -40 || true"))
        print("DIAG ps count:", crun("ps aux 2>&1 | wc -l || true"))
        print("DIAG host container pids:", appliance.succeed("cat /sys/fs/cgroup/machine.slice/container@runner.service/pids.current /sys/fs/cgroup/machine.slice/container@runner.service/pids.max 2>&1 || true"))
        raise
    print(f"OK: pre-swap build through the relocated store: {proof_v1}")

    if CASCADE and not EPHEMERAL:
        v1_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        v1_current = appliance.succeed(
          f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
        ).strip()
        v1_runner_upper = f"{v1_current}/layers/runner/upper"
        v1_db_path = f"{v1_current}/layers/runner/state/db/db.sqlite"
        proof_v1_name = proof_v1.rsplit("/", 1)[-1]
        v1_proof_hash = appliance.succeed(
          f"sha256sum {v1_runner_upper}/{proof_v1_name} | awk '{{print $1}}'"
        ).strip()
        v1_db_hash = appliance.succeed(
          f"sha256sum {v1_db_path} | awk '{{print $1}}'"
        ).strip()
  '' + (if ephemeral then ''
    proof_v1_name = proof_v1.rsplit("/", 1)[-1]
    appliance.succeed("test -f /srv/bincache/overlay/upper/" + proof_v1_name)
    appliance.succeed("systemctl stop container@runner.service")
    ephemeral_paths = [
      "/srv/bincache/overlay/upper",
      "/srv/bincache/overlay/work",
      "/srv/bincache/nix/var/nix/db",
      "/srv/bincache/nix/var/nix/gcroots",
      "/srv/bincache/nix/var/nix/profiles",
      "/srv/bincache/nix/var/nix/temproots",
    ]
    for path in ephemeral_paths:
        appliance.succeed(f"mkdir -p {path} && touch {path}/ephemeral-sentinel")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet container@runner.service", timeout=600
    )
    appliance.wait_until_succeeds(
      "nixos-container run runner -- systemctl is-active nix-daemon-custom", timeout=600
    )
    for path in ephemeral_paths:
        appliance.fail(f"test -e {path}/ephemeral-sentinel")
    appliance.fail("test -e /srv/bincache/overlay/upper/" + proof_v1_name)
    cfail(
      "nix --extra-experimental-features nix-command path-info "
      "--store unix:///srv/nix/var/nix/daemon-socket/socket " + proof_v1
    )
    crun("test -f /run/nixtache-runner-lower/nix/var/nix/lower-state/db/db.sqlite")
    proof_reset = build_proof("after-ephemeral-reset")
    assert crun("cat /srv/nix/store/" + proof_reset.rsplit("/", 1)[-1]).strip() == "after-ephemeral-reset"
    print("PASS: ephemeral host upper resets the complete runner descendant and preserves a coherent parent lower")
  '' else ''
    # -- Stage v2 SIGNED → sysupdate → slot B -------------------------------
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

    if CASCADE:
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=3600)
        v2_slot = appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip()
        v2_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        v2_target = f"/var/lib/nix-overlay/upper-slots/{v2_slot}/generations/{v2_generation}"
        appliance.succeed(f"grep -q '^state=ready$' {v2_target}/metadata")
        appliance.succeed(f"test -f {v2_target}/layers/runner/upper/{proof_v1_name}")
        assert appliance.succeed(
          f"sha256sum {v1_runner_upper}/{proof_v1_name} | awk '{{print $1}}'"
        ).strip() == v1_proof_hash
        assert appliance.succeed(
          f"sha256sum {v1_db_path} | awk '{{print $1}}'"
        ).strip() == v1_db_hash
        print("OK: parent-first reconcile cloned the runner upper without mutating the active source")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target", timeout=3600)
    assert appliance.succeed("cat /etc/image-version").strip() == "2"
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet container@runner.service", timeout=600
    )
    print("OK: v2 booted; runner container up post-swap")
  '' + (
    if storeMode == "clone" then ''
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-custom",
        timeout=900
      )
      proof_v1_name = proof_v1.rsplit("/", 1)[-1]
      assert crun("cat /srv/nix/store/" + proof_v1_name).strip() == "v1"
      crun(
        "nix --extra-experimental-features nix-command path-info "
        "--store unix:///srv/nix/var/nix/daemon-socket/socket "
        "/nix/store/${helloBasename} >/dev/null"
      )
      print("OK: clone is additive — old build output kept, new lower content arrived")
      proof_v2 = build_proof("v2")
      assert proof_v2 != proof_v1
      proof_v2_name = proof_v2.rsplit("/", 1)[-1]
      assert crun("cat /srv/nix/store/" + proof_v2_name).strip() == "v2"
      print("PASS: runner clone store serves CI builds across an OTA swap")
    '' else ''
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-overlay-mount",
        timeout=600
      )
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-custom",
        timeout=600
      )
      assert crun("cat /srv/nix/store/" + proof_v1_name).strip() == "v1"
      crun(
        "nix --extra-experimental-features nix-command path-info "
        "--store unix:///srv/nix/var/nix/daemon-socket/socket "
        "/nix/store/${helloBasename} >/dev/null"
      )
      crun("test -f /run/nixtache-runner-lower/nix/var/nix/lower-state/db/db.sqlite")
      print("OK: selected parent store and metadata remain coherent through the dedicated lower root")

      proof_v2 = build_proof("v2")
      assert proof_v2 != proof_v1
      proof_v2_name = proof_v2.rsplit("/", 1)[-1]
      assert crun("cat /srv/nix/store/" + proof_v2_name).strip() == "v2"
      appliance.fail(f"test -e {v1_runner_upper}/{proof_v2_name}")
      assert appliance.succeed(
        f"sha256sum {v1_runner_upper}/{proof_v1_name} | awk '{{print $1}}'"
      ).strip() == v1_proof_hash
      assert appliance.succeed(
        f"sha256sum {v1_db_path} | awk '{{print $1}}'"
      ).strip() == v1_db_hash
      print("OK: v2 CI writes are isolated from the inactive v1 runner upper and DB")

      for boot in (1, 2):
          if boot == 2:
              appliance.reboot()
              appliance.wait_for_unit("multi-user.target", timeout=3600)
              assert appliance.succeed("cat /etc/image-version").strip() == "2"
          appliance.wait_until_succeeds(
            "systemctl is-failed --quiet nixtache-runner-rollback-canary.service", timeout=120
          )
          appliance.wait_until_fails(
            "systemctl is-active --quiet nixtache-health-check.service", timeout=120
          )
          print(f"OK: v2 boot {boot} ran the runner but remained unblessed")

      appliance.reboot()
      appliance.wait_for_unit("multi-user.target", timeout=3600)
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      appliance.wait_until_succeeds(
        "systemctl is-active --quiet container@runner.service", timeout=600
      )
      appliance.wait_until_succeeds(
        "nixos-container run runner -- systemctl is-active nix-daemon-custom", timeout=600
      )
      assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == v1_slot
      assert appliance.succeed(
        f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
      ).strip() == v1_current
      appliance.succeed(f"test -f {v1_runner_upper}/{proof_v1_name}")
      assert crun("cat /srv/nix/store/" + proof_v1_name).strip() == "v1"
      cfail(
        "nix --extra-experimental-features nix-command path-info "
        "--store unix:///srv/nix/var/nix/daemon-socket/socket " + proof_v2
      )
      assert appliance.succeed(
        f"sha256sum {v1_db_path} | awk '{{print $1}}'"
      ).strip() == v1_db_hash
      print("PASS: failed-boot rollback restores the original runner generation and DB without reverse repair")
    ''
  ));
}

# Runner + A/B compatibility VM tests (spec TEST-SPECS sec. 4 R1/R2, review sec. 11.3).
#
# THE APPLIANCE CONDITION (sec. 11.3): on an A/B appliance the container has NO
# usable system nix-daemon — the image-based-appliance profile forces
# nix.enable=false, so inside the runner container there is no
# nix-daemon.service to require or to seed the clone through. The store.nix
# contract after the sec. 11.3 fix:
#   - clone on a nix-enabled container (non-appliance): nix-daemon-storage
#     requires nix-daemon.service and seeds via NIX_REMOTE=daemon (unchanged);
#   - clone on an appliance-style container (nix.enable=false): storage has NO
#     requires and clones standalone from the local store (scratch DB copy);
#     nix-daemon-custom runs standalone;
#   - overlay mode: no storage service at all (covered by
#     tests/runner-store-mode-vm.nix, not duplicated here).
#
# STRATEGY (mirrors runner-store-mode-vm's "simulate the appliance condition"
# approach, spec sec. 4.2 allows "отдельная VM-сборка"): regular runNixOSTest
# nodes boot the runner container; the `appliance` node reproduces the exact
# sec. 11.3 condition by setting `containers.runner.config.nix.enable = false`
# (plus nix.gc.automatic=false — nixpkgs asserts gc → nix.enable). Booting the
# real mkAppliance raw image is the pexpect/multi-boot territory of R4 below,
# not needed for the single-boot clone/build contract.
#
# Covered:
#   R1 clone-after-boot on BOTH sec. 11.3 modes: /srv/nix/store populated,
#      nix-daemon-storage active (RemainAfterExit), nix-daemon-custom active;
#      appliance node additionally proves nix-daemon.service is absent and the
#      storage unit carries no Requires.
#   R2 build-through-relocated-store: a trivial derivation built through the
#      custom daemon socket (from the host, via the shared hostBackup path)
#      lands in /srv/nix/store. Run on the appliance node (the key case).
#
# SKIPPED (documented, not faked):
#   R4 ab-runner-reclone-after-swap (sec. 4.4): needs two full mkAppliance image
#      builds (v1/v2, each embedding the runner container closure) plus a
#      multi-boot pexpect driver that runs systemd-sysupdate between boots and
#      re-verifies the clone is additive. Beyond driver cost there is an
#      unresolved HOST-side prerequisite outside this file's scope: the
#      nixpkgs container machinery unconditionally `--bind-ro`s the host's
#      /nix/var/nix/db and /nix/var/nix/daemon-socket into the container, so
#      booting the runner container on a nix-less appliance (nix.enable=false)
#      first needs those paths guaranteed on the appliance rootfs (ab-image /
#      runner host-side work). The single-boot in-container contract R4 builds
#      on IS proven here; the clone's additive property (`nix copy --all` into
#      an existing store adds new paths, keeps old) is a nix-level guarantee
#      the module does not alter.
#      → skip-with-reason: multi-boot pexpect driver + double image build +
#        host-side container-bind prerequisite on nix-less appliances.
#   RO6 runner-overlay-ab-swap (sec. 7.7): same multi-boot driver + host-side
#      prerequisite cost, for the overlay mode whose single-boot contract is
#      already covered by tests/runner-store-mode-vm.nix (RO1-RO5). Upper
#      persistence across a swap follows from the upper dir living on the
#      persistent root FS (<store.path>/overlay/upper), which the module wires
#      statically.
#      → skip-with-reason: same as R4.
#   RO7 runner-overlay-boot-time (sec. 7.8): stays a MANUAL benchmark — VM boot
#      timing under a shared CI hypervisor is too noisy for a meaningful
#      assert (spec itself relaxes it to "overlay ≤ clone"); the structural
#      fact (overlay mode performs no `nix copy --all` at boot) is already
#      asserted by RO2 in tests/runner-store-mode-vm.nix.
#
# Needs KVM (runNixOSTest boots QEMU). `requiredSystemFeatures` is set
# internally by `pkgs.testers.runNixOSTest`, so `nix flake check` on a
# non-KVM host skips it without breaking routine checks.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Shared runner wiring for both nodes: relocated store at /srv (host backup
  # /srv/bincache), clone mode (the default), sandbox off (unreliable in
  # nspawn), cache off (not under test here).
  runnerCfg = {
    imports = [ self.nixosModules.runner ];
    services.nixtache.runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache.enable = false;
      instances.default = { uuid = "00000000-0000-4000-8000-000000000000"; tokenFile = toString /dev/null; };
      secrets.cachePrivateKey = toString /dev/null;
      store.path = "/srv";
      enableSandbox = false;
    };
    # The clone copies the whole registered store closure into /srv/bincache
    # on the root disk — give it room (sparse) and the copy some RAM/cores.
    virtualisation.diskSize = 40 * 1024;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
  };
in
pkgs.testers.runNixOSTest {
  name = "ab-runner-compat";

  nodes = {
    # sec. 11.3 non-appliance mode: container nix enabled (default) — storage
    # requires the system nix-daemon and seeds through it.
    normal = { ... }: {
      imports = [ runnerCfg ];
    };

    # sec. 11.3 appliance mode: no system nix-daemon in the container — storage
    # clones standalone, nix-daemon-custom runs standalone.
    appliance = { lib, ... }: {
      imports = [ runnerCfg ];
      containers.runner.config = {
        nix.enable = false;
        # nixpkgs asserts nix.{gc,optimise}.automatic → nix.enable, so both
        # timers go with the daemon (nixos-containers.nix sets them — force off).
        nix.gc.automatic = lib.mkForce false;
        nix.optimise.automatic = lib.mkForce false;
      };
    };
  };

  testScript = ''
    import shlex

    # Run a command as root INSIDE a node's runner container. Returns stdout.
    def crun(node, inner):
        return node.succeed(
            "nixos-container run runner -- /bin/sh -c " + shlex.quote(inner)
        )

    # Wait for the clone contract on one node: storage oneshot done
    # (RemainAfterExit → stays "active") and the custom daemon up. The clone
    # copies the whole store closure — generous timeout. On failure, dump the
    # storage journal + the nix-copy log before re-raising.
    def wait_clone(node):
        try:
            node.wait_until_succeeds(
                "nixos-container run runner -- systemctl is-active nix-daemon-storage",
                timeout=1800,
            )
            node.wait_until_succeeds(
                "nixos-container run runner -- systemctl is-active nix-daemon-custom",
                timeout=600,
            )
        except Exception:
            print("DIAG journalctl nix-daemon-storage:")
            print(node.succeed(
                "nixos-container run runner -- "
                "journalctl -u nix-daemon-storage --no-pager 2>&1 | tail -20 || true"
            ))
            print("DIAG /var/log/nix-copy-setup.log:")
            print(node.succeed(
                "nixos-container run runner -- "
                "cat /var/log/nix-copy-setup.log 2>&1 || true"
            ))
            print("DIAG nix-daemon-custom status:")
            print(node.succeed(
                "nixos-container run runner -- "
                "systemctl status nix-daemon-custom --no-pager 2>&1 | tail -20 || true"
            ))
            raise

    # R1 body, shared by both sec. 11.3 modes.
    def check_r1(node, label):
        assert "active" in crun(node, "systemctl is-active nix-daemon-storage"), \
            label + ": nix-daemon-storage not active (clone did not finish)"
        assert "active" in crun(node, "systemctl is-active nix-daemon-custom"), \
            label + ": nix-daemon-custom not active"
        count = int(crun(node, "ls /srv/nix/store | wc -l").strip())
        assert count > 0, label + ": /srv/nix/store is empty after the clone"
        print(label + " R1 OK: store cloned to /srv/nix (" + str(count) +
              " paths), nix-daemon-custom active")

    start_all()
    # The container's start job blocks its host's multi-user.target until the
    # inner clone oneshot finishes (nspawn notify-ready) — generous timeout.
    # On the appliance node we do NOT wait for multi-user: polling the
    # container units directly (wait_clone) gives diagnostics on a stuck clone
    # instead of a bare target timeout.
    normal.wait_for_unit("multi-user.target", timeout=1800)
    normal.succeed("systemctl start container@runner.service --no-block")
    appliance.succeed("systemctl start container@runner.service --no-block")
    normal.wait_for_unit("container@runner.service", timeout=1800)

    # -- R1, non-appliance mode: requires + seed through the system daemon --
    wait_clone(normal)
    req = crun(normal, "systemctl show -p Requires nix-daemon-storage")
    assert "nix-daemon.service" in req, \
        "non-appliance clone must keep Requires=nix-daemon.service"
    # NB: the inner nix-daemon.service legitimately stays inactive (its start
    # condition is skipped inside a container) — the seed actually goes
    # through the host's daemon socket, ro-bound into the container. The
    # sec. 11.3 contract is about the Requires wiring, not the daemon's state.
    check_r1(normal, "R1/normal")

    # -- R1, appliance mode (sec. 11.3): standalone clone, no system daemon -----
    # Early diagnostic snapshot: the standalone clone has been running since
    # container start — show its state before the long wait.
    print("EARLY DIAG appliance nix-daemon-storage:")
    print(appliance.succeed(
        "nixos-container run runner -- "
        "systemctl status nix-daemon-storage --no-pager 2>&1 | tail -12 || true"
    ))
    print("EARLY DIAG appliance /var/log/nix-copy-setup.log:")
    print(appliance.succeed(
        "nixos-container run runner -- "
        "tail -20 /var/log/nix-copy-setup.log 2>&1 || true"
    ))
    wait_clone(appliance)
    sysd = crun(appliance,
        "systemctl list-unit-files nix-daemon.service >/dev/null 2>&1 "
        "&& echo PRESENT || echo ABSENT")
    assert "ABSENT" in sysd, \
        "appliance container (nix.enable=false) must have no nix-daemon.service"
    req_a = crun(appliance, "systemctl show -p Requires nix-daemon-storage")
    assert "nix-daemon.service" not in req_a, \
        "appliance clone must NOT require the (absent) system nix-daemon"
    req_c = crun(appliance, "systemctl show -p Requires nix-daemon-custom")
    assert "nix-daemon-storage.service" in req_c and \
           "nix-daemon.service" not in req_c, \
        "appliance: nix-daemon-custom must depend only on the storage oneshot"
    check_r1(appliance, "R1/appliance")

    # -- R2: a build through the custom daemon socket lands in /srv/nix -----
    # The socket is reachable from the host at the hostBackup path (same
    # bind). Build a trivial derivation — no network, sandbox off (nspawn
    # without CAP_SYS_ADMIN). The builder is the guest's own /bin/sh (part of
    # the node closure, carried into /srv/nix/store by the clone).
    builder = appliance.succeed("readlink -f /bin/sh").strip()
    print("DIAG appliance nix-daemon-custom unit env:")
    print(appliance.succeed(
        "nixos-container run runner -- "
        "systemctl cat nix-daemon-custom 2>&1 | grep -E 'NIX_CONFIG|build-users|ExecStart' || true"
    ))
    print("DIAG appliance host build-users-group:")
    print(appliance.succeed("grep build-users-group /etc/nix/nix.conf || echo unset"))
    out = appliance.succeed(
        "nix --extra-experimental-features nix-command "
        "build --no-link --print-out-paths "
        "--store unix:///srv/bincache/nix/var/nix/daemon-socket/socket "
        "--option sandbox false --option substitute false "
        "--option build-users-group \"\" "
        "--expr 'derivation { name = \"ab-runner-compat-proof\"; "
        "system = \"${system}\"; builder = \"" + builder + "\"; "
        "args = [ \"-c\" \"echo ok > $out\" ]; }' 2>&1"
    ).strip().splitlines()[-1]
    print("R2 build output: " + out)
    assert "-ab-runner-compat-proof" in out, "unexpected build output path"
    print("DIAG host-side store dir:")
    print(appliance.succeed(
        "ls -d /srv/bincache/nix/store/*ab-runner-compat-proof 2>&1 || "
        "ls /srv/bincache 2>&1 || true"
    ))
    assert "-ab-runner-compat-proof" in crun(
        appliance, "ls -d /srv/nix/store/*-ab-runner-compat-proof"), \
        "build output not visible inside the container at /srv/nix/store"
    print("R2 OK: build through the custom daemon socket landed in /srv/nix/store")

    print("RESULT_R1_R2=yes")
  '';
}

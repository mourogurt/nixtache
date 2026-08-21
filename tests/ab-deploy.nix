# ab-deploy — CI-faithful LIVE deploy E2E via runNixOSTest (method = "live").
#
# The live-path counterpart of tests/ab-deploy-e2e.nix (which owns the
# ab-image path): the REAL `.forgejo/actions/deploy-target/action.yml`
# composite `run:` text is extracted at build time (Python yaml parse of the
# actual file) and executed on the deployer node with the env the Forgejo
# runner would export (GITHUB_EVENT_NAME/REF → mode, NIXTACHE_DEPLOY_TARGETS
# with method="live", SANDBOX_OK, CREDENTIALS_DIRECTORY with the deploy key).
#
# Fake-nix boundary: a wrapper stubs ONLY `nix flake show` (answers the deploy
# map's config name) and `nix build` (echoes a PREBUILT toplevel store path —
# the VM has no internet for real flake evaluation). Everything else the live
# path uses runs for REAL, delegated to the real nix binary: `nix copy --to
# ssh://` pushes the closure over REAL ssh, and the final
# `ssh … systemctl start nixtache-apply.service` triggers the REAL root apply
# unit on the target (polkit-authorized for the deploy user). One extra stub
# outside fake-nix: `nixos-rebuild` (a separate binary the dry-activate branch
# shells out to) is a no-op logger — a real dry-activate needs flake
# evaluation (no internet) and remote sudo (the deploy user has none).
#
# The "new system" the action deploys is a THIRD node (`targetNew`) that is
# never booted: the same shared module as the running `target` plus one marker
# file (/etc/deploy-marker). The shared module pins the nodeNumber-dependent
# network identity (eth1 addresses) so the two toplevels have an IDENTICAL
# unit set — switch-to-configuration restarts nothing, so the test-driver
# backdoor AND the deployer's ssh session (inside which the synchronous
# `systemctl start` blocks) both survive the activation. Unlike a
# specialisation, the marker toplevel is NOT part of the running target's
# closure, so `nix copy` has something real to transfer (proving the push).
# The deployer registers the toplevel in its nix db via
# virtualisation.additionalPaths so the real `nix copy` sees a valid path.
#
# The target imports the REAL `nixosModules.deploy-target`: deployUser
# (authorizedKey from tests/ab-fixture.nix), criticalUnits = sshd.service
# (trivial, always active), health-check defaults. The deploy user lands in
# `nix.settings.trusted-users` (deployUser.nixTrust) — without it the daemon
# rejects the unsigned closure push.
#
# Assertions, in CI order:
#   dry-activate run (non-main ref): the log shows the dry branch, the
#     nixos-rebuild stub WAS invoked, and NOTHING mutated — profile unchanged,
#     no pointer file, toplevel not valid in the target store.
#   switch run (main ref): the toplevel closure is valid in the target store
#     (`nix path-info`), the system profile points at it, /etc/deploy-marker
#     exists (switch-to-configuration really ran), the pointer file was
#     consumed by the apply unit, the criticalUnits probe passed (the
#     synchronous systemctl start returned 0; the journal shows "activated"),
#     sshd still active.
#
# Retains two orthogonal pieces of the old suite's coverage:
#   - action.yml parse assertions (single-source contract on the live path);
#   - runner-module nginx ab staging: the deployer imports the REAL
#     `nixosModules.runner` with deploy.ab.enable and the test curls a staged
#     file + autoindex through the module-wired nginx location (the runtime
#     serve path; eval-level coverage lives in tests/runner.nix).
#
# Needs KVM (runNixOSTest boots QEMU; requiredSystemFeatures = ["kvm"] is set
# by the framework itself).
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };

  # The single config name the deploy map + fake `nix flake show` agree on.
  cfgName = "livetest";

  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;

  # Extract the composite step's `run:` text at BUILD TIME — the SINGLE source
  # of the deploy logic (see ab-deploy-e2e.nix for the same technique).
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

  # Fake `nix` wrapper — stubs exactly the two commands that need flake
  # evaluation (no internet in the VM), delegates everything else (notably
  # `nix copy`) to the real nix binary.
  fakeNix = pkgs.writeShellScript "fake-nix" ''
    if [ "$1" = "flake" ] && [ "$2" = "show" ]; then
      echo '${builtins.toJSON { nixosConfigurations.${cfgName} = { }; }}'
      exit 0
    fi
    if [ "$1" = "build" ]; then
      echo '${newToplevel}'
      exit 0
    fi
    exec ${pkgs.nix}/bin/nix "$@"
  '';

  # The dry-activate branch runs `nixos-rebuild --target-host --use-remote-sudo`
  # — a separate binary, so fake-nix never sees it. Stub it as a no-op logger:
  # the dry run's point is proving the branch makes NO mutation, and the marker
  # file proves the branch was actually taken.
  fakeNixosRebuild = pkgs.writeShellScript "fake-nixos-rebuild" ''
    echo "nixos-rebuild(stub): $*"
    touch /tmp/nixos-rebuild-called
  '';

  # JSON deploy map — the same shape the nixtache runner module exports as
  # NIXTACHE_DEPLOY_TARGETS.
  deployTargets = builtins.toJSON {
    ${cfgName} = {
      method = "live";
      sshUser = "nixos-deploy";
      host = "target";
      sshPort = "22";
      hasKey = true;
      enable = true;
      extraOptions = [ ];
    };
  };

  # Env sourced before running the action script — the variables the Forgejo
  # runner would export, EXCEPT GITHUB_REF which each run sets per-invocation
  # (dry vs switch mode).
  deployEnvFile = pkgs.writeText "deploy-env" ''
    export GITHUB_EVENT_NAME=push
    export SANDBOX_OK=0
    export NIXTACHE_DEPLOY_TARGETS='${deployTargets}'
    export CREDENTIALS_DIRECTORY=/run/credentials
    export PATH=/etc/fake-nix:$PATH
  '';

  # Shared by the running `target` and the never-booted `targetNew` variant.
  # The eth1 addresses are pinned because the framework derives them from the
  # (readOnly) nodeNumber: without the pin, targetNew's .network / address
  # units would differ from the running target's and switch-to-configuration
  # would restart networking — killing the deployer's ssh session mid-`systemctl
  # start`. The pinned values match what `target` gets anyway (it is
  # alphabetically the 2nd node: deployer=1, target=2, targetNew=3).
  targetCommon = { pkgs, lib, ... }: {
    imports = [ self.nixosModules.deploy-target ];
    services.openssh.enable = true;
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      { address = "192.168.1.2"; prefixLength = 24; }
    ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      { address = "2001:db8:1::2"; prefixLength = 64; }
    ];

    # Writable store (overlayfs upper on tmpfs) so `nix copy --to ssh://` can
    # import the closure into the target's store via the daemon.
    virtualisation.writableStore = true;
    virtualisation.memorySize = 4096;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    # Test VMs default system.switch.enable off; production targets (and the
    # apply unit's `$P/bin/switch-to-configuration`) need it on.
    system.switch.enable = true;

    # Test VMs boot via qemu -kernel; no installable boot device exists, so the
    # bootloader install step of switch-to-configuration would fail (GRUB on
    # /dev/disk/by-id/virtio-root). Disable it — production targets keep theirs.
    boot.loader.grub.enable = false;

    services.nixtache.deploy-target = {
      enable = true;
      criticalUnits = [ "sshd.service" ]; # trivial, always active
      healthCheckTimeout = 60;
      deployUser = {
        name = "nixos-deploy";
        authorizedKey = fixture.deployKeyPub;
        autoProvision = true;
      };
    };
  };

  test = pkgs.testers.runNixOSTest {
    name = "ab-deploy";

    nodes.deployer = { pkgs, lib, ... }: {
      imports = [ self.nixosModules.runner ];
      # Runner-module ab staging (old suite's Q1): nginx ab-stage location +
      # central staging dir + signing key, provisioned by the REAL module. The
      # CI container is OFF — host-side provisions only.
      services.nginx.enable = true;
      services.nixtache.runner = {
        enable = true;
        forgejoUrl = "http://localhost:3000";
        cache = { enable = true; domain = "localhost"; port = 5000; };
        instances.default.tokenFile = toString /dev/null;
        secrets.cachePrivateKey = toString /dev/null;
        store.path = "/"; # native store; no relocated-store daemon needed here
        deploy.ab = {
          enable = true;
          runnerHost = "localhost";
          signingKeyFile = "${fixture.testSignKey}/priv.asc";
        };
      };
      containers.runner.autoStart = lib.mkForce false;
      # The cache vhost defaults to HTTPS+ACME; force plain HTTP for the VM
      # (no real domain/LetsEncrypt). The ab-stage location itself is unchanged.
      services.nginx.virtualHosts."localhost".forceSSL = lib.mkForce false;
      services.nginx.virtualHosts."localhost".enableACME = lib.mkForce false;

      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = with pkgs; [ curl jq openssh ];
      environment.etc."deploy-action.sh".source = "${actionRunScript}";
      environment.etc."deploy-env.sh".source = "${deployEnvFile}";
      environment.etc."fake-nix/nix".source = "${fakeNix}";
      environment.etc."fake-nix/nixos-rebuild".source = "${fakeNixosRebuild}";
      # Deploy SSH key (copied into CREDENTIALS_DIRECTORY by the test script).
      environment.etc."deploy-key".source = "${fixture.testDeployKey}/id_ed25519";
      # The prebuilt toplevel, registered in the guest nix db at boot so the
      # REAL `nix copy` sees it (and its closure) as valid.
      virtualisation.additionalPaths = [ newToplevel ];
    };

    nodes.target = targetCommon;

    # Never started — exists only to build the "update" toplevel with an
    # identical unit set (shared module) plus the marker file.
    nodes.targetNew = { ... }: {
      imports = [ targetCommon ];
      environment.etc."deploy-marker".text = "live-v2";
    };

    testScript = ''
      import yaml

      # ── Parse the REAL action.yml to verify the extracted script is genuine ──
      action = yaml.safe_load(${builtins.toJSON actionYml})
      run_text = next(s["run"] for s in action["runs"]["steps"] if "run" in s)
      assert "_liveApply" in run_text, "action.yml missing the live apply function"
      assert "config.system.build.toplevel" in run_text, "action.yml missing the toplevel build"
      assert run_text.count("config.system.build.toplevel") == 1, \
          "action.yml must build the toplevel exactly once"
      assert "nix copy --to" in run_text, "action.yml missing the closure push"
      assert "NIX_SSHOPTS" in run_text, "action.yml must pass the deploy key to nix copy"
      assert "pending-system" in run_text, "action.yml missing the apply pointer file"
      assert "nixtache-apply.service" in run_text, "action.yml missing the apply-unit trigger"
      print("OK: parsed action.yml (%d chars of run text)" % len(run_text))

      # ── Boot both nodes ──────────────────────────────────────────────────────
      deployer.start()
      target.start()
      deployer.wait_for_unit("nginx.service")
      target.wait_for_unit("sshd.service")
      # The Tier-0 health-check oneshot (criticalUnits probe) ran successfully
      # at boot — Result=success (oneshot goes inactive after completing).
      target.wait_until_succeeds(
        "systemctl show -p Result --value nixtache-health-check.service | grep -qx success",
        timeout=120
      )

      # ── Runner-module nginx staging (old Q1): the module-wired ab-stage
      #    location actually serves staged files over HTTP ────────────────────
      deployer.succeed("test -d /var/lib/nixtache/ab-stage")
      deployer.succeed("mkdir -p /var/lib/nixtache/ab-stage/cfg && echo BODY > /var/lib/nixtache/ab-stage/cfg/x")
      deployer.succeed("curl -sf http://localhost/ab-stage/cfg/x | grep BODY")
      deployer.succeed("curl -sf http://localhost/ab-stage/cfg/ | grep -i x")  # autoindex on
      deployer.succeed("test -s ${fixture.testSignKey}/priv.asc")
      print("OK: runner module nginx serves ab-stage + signing key present")

      # ── Credentials directory (the deploy key, LoadCredential-style) ────────
      deployer.succeed(
        "mkdir -p /run/credentials && "
        "cp /etc/deploy-key /run/credentials/deploy_ssh_${cfgName} && "
        "chmod 600 /run/credentials/deploy_ssh_${cfgName}"
      )

      pre_profile = target.succeed("readlink -f /nix/var/nix/profiles/system").strip()

      def run_action(ref):
          """Run the REAL action.yml script with the given git ref (mode).
          Returns the per-target deploy log."""
          deployer.succeed("rm -f /tmp/artifacts/deploy_${cfgName}.log /tmp/nixos-rebuild-called")
          # fake-nix on PATH intercepts `nix flake show` + `nix build`;
          # `nix copy` delegates to the REAL nix — closure push + ssh trigger
          # run verbatim from action.yml's run text.
          deployer.succeed(
            f"cd /tmp && . /etc/deploy-env.sh && GITHUB_REF={ref} bash /etc/deploy-action.sh",
            timeout=600
          )
          return deployer.succeed("cat /tmp/artifacts/deploy_${cfgName}.log")

      # ── RUN 1: dry-activate (non-main ref) — build + dry branch, no mutation ─
      log = run_action("refs/heads/staging")
      assert "dry-activate (no mutation)" in log, "dry run did not take the dry-activate branch: " + log[-500:]
      # The dry branch's nixos-rebuild WAS invoked (stub logger marker).
      deployer.succeed("test -f /tmp/nixos-rebuild-called")
      # Nothing mutated on the target: profile unchanged, no pointer file, the
      # toplevel was NOT pushed (not valid in the target's nix db).
      assert target.succeed("readlink -f /nix/var/nix/profiles/system").strip() == pre_profile, \
          "dry-activate changed the system profile"
      target.fail("test -e /var/lib/nixtache/pending-system")
      target.fail("nix path-info ${newToplevel}")
      target.fail("test -e /etc/deploy-marker")
      print("OK: RUN 1 — dry-activate took the dry branch, target untouched")

      # ── RUN 2: switch (main ref) — copy closure → pointer → apply unit ──────
      # On failure, dump the apply unit's journal — the probe/rollback detail
      # lives on the target, not in the deploy log.
      try:
          log = run_action("refs/heads/main")
      except Exception:
          print("--- nixtache-apply.service journal on target ---")
          print(target.succeed("journalctl -u nixtache-apply.service --no-pager -o cat || true"))
          raise
      assert "activated ${newToplevel}" in log, "switch run did not activate: " + log[-500:]

      # The closure arrived via the REAL `nix copy --to ssh://` (deploy user is
      # in nix.settings.trusted-users via the module's deployUser.nixTrust).
      target.succeed("nix path-info ${newToplevel}")
      # The apply unit set the system profile to the staged toplevel…
      profile = target.succeed("readlink -f /nix/var/nix/profiles/system").strip()
      assert profile == "${newToplevel}", f"system profile not switched: {profile}"
      # …and switch-to-configuration really ran (the marker /etc file is only
      # in the NEW config)…
      target.succeed("grep -q live-v2 /etc/deploy-marker")
      target.succeed("test \"$(readlink -f /run/current-system)\" = ${newToplevel}")
      # …and consumed the pointer file.
      target.fail("test -e /var/lib/nixtache/pending-system")
      # The criticalUnits probe passed (the synchronous `systemctl start`
      # returned 0 — the action would have failed otherwise) and the unit
      # logged the activation.
      target.succeed("systemctl is-active --quiet sshd.service")
      journal = target.succeed("journalctl -u nixtache-apply.service --no-pager -o cat")
      assert "activated ${newToplevel}" in journal, "apply unit journal: " + journal[-500:]
      print("OK: RUN 2 — closure copied, profile switched, criticalUnits probe passed")

      print("PASS: runtime action.yml (method=live) → nix copy → pointer → nixtache-apply activated the new system")
    '';
  };

  # The "update" the action deploys — see the header for why this is a third,
  # never-booted node with a pinned network identity.
  newToplevel = test.nodes.targetNew.system.build.toplevel;
in
test

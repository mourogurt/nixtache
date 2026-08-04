# Pure-evaluation tests for the forgejo-runner module.
#
# The module is consumed by nixtache itself (dogfooding): each scenario imports
# `self.nixosModules.forgejo-runner` and feeds it a per-instance `tokenFile`
# pointing at nixtache's own (sops-encrypted) `secrets/runner.env`. These
# checks verify the module WIRING without running any container/VM — the token
# file is ciphertext, which is fine since the module never reads it at eval
# time (a live deployment would decrypt it via sops-nix first).
#
#   - "/srv" → relocate the store to <path>/nix: custom nix-daemon + storage
#              oneshot, BindPaths onto /nix injected into every runner service
#              + nix-serve, `after/requires = nix-daemon-custom.service`;
#   - "/"    → reuse the container's system nix-daemon (no custom services);
#   - ""     → the mandatory-path assertion fires;
#   - multi  → one `gitea-runner-<name>` per instance, each relocated-store
#              wired, with its own token mount + name/labels;
#   - ssh    → optional SSH key pair: absent = no LoadCredential / key mounts;
#              present = LoadCredential + mounts wired; half-set = assertion.
#
# Exposed via the flake as `checks.<system>.forgejo-runner`.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Dummy secret for paths the module forwards but never reads at eval time.
  dummySecret = /dev/null;

  # nixtache's own (sops-encrypted) runner registration token — used as the
  # per-instance `tokenFile` so the test consumes the module exactly like a
  # real consumer would.
  runnerToken = ../secrets/runner.env;

  # Minimal host + module config shared by every scenario. One `default`
  # instance, real token, cache key, and NO SSH keys (build-only / test — no
  # fbot push-back). Only `store.path` (and the `extra` module) varies.
  baseModule = { ... }: {
    system.stateVersion = "24.11";
    services.nixtache.forgejo-runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache = {
        enable = true;
        domain = "bincache.test";
        port = 5000;
      };
      instances.default.tokenFile = runnerToken;
      secrets.cachePrivateKey = dummySecret;
      # sshPrivateKey / sshPublicKey intentionally omitted (optional).
    };
  };

  mkHost = storePath: extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.forgejo-runner
        baseModule
        { services.nixtache.forgejo-runner.store.path = storePath; }
        extra
      ];
    };

  containerCfg = host: host.config.containers."forgejo-runner".config;
  servicesOf = host: (containerCfg host).systemd.services;
  socketsOf = host: (containerCfg host).systemd.sockets;
  bindMountsOf = host: host.config.containers."forgejo-runner".bindMounts;
  instancesOf = host: (containerCfg host).services.gitea-actions-runner.instances;
  loadCred = svc: svc."gitea-runner-default".serviceConfig.LoadCredential or [ ];
  has = set: name: set ? ${name};

  # --- scenario A: relocated store, SSH off -------------------------------
  hostSrv = mkHost "/srv" { };
  svcSrv = servicesOf hostSrv;
  scenarioSrv = {
    name = "store.path=\"/srv\" relocates the store; SSH off → no key wiring";
    checks = {
      hasCustomDaemon = has svcSrv "nix-daemon-custom";
      hasStorage = has svcSrv "nix-daemon-storage";
      hasSocket = has (socketsOf hostSrv) "nix-daemon-custom";
      daemonBindPaths = svcSrv."nix-daemon-custom".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      giteaBindPaths = svcSrv."gitea-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      giteaRequires = lib.elem "nix-daemon-custom.service" (svcSrv."gitea-runner-default".requires or [ ]);
      giteaAfter = lib.elem "nix-daemon-custom.service" (svcSrv."gitea-runner-default".after or [ ]);
      nixServeBindPaths = svcSrv."nix-serve".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      socketPath = (socketsOf hostSrv)."nix-daemon-custom".listenStreams == [ "/srv/nix/var/nix/daemon-socket/socket" ];
      srvMountPoint = (bindMountsOf hostSrv)."srv-nix".mountPoint == "/srv";
      # per-instance token mount present, SSH mounts / LoadCredential absent
      tokenMount = (bindMountsOf hostSrv)."forgejo-token-default".mountPoint == "/var/secrets/forgejo-runner/default/token";
      noSshPrivateMount = !(has (bindMountsOf hostSrv) "ssh-private-key");
      noLoadCredential = loadCred svcSrv == [ ];
    };
  };

  # --- scenario B: native store -------------------------------------------
  hostRoot = mkHost "/" { };
  svcRoot = servicesOf hostRoot;
  scenarioRoot = {
    name = "store.path=\"/\" reuses the system nix-daemon (no custom services)";
    checks = {
      noCustomDaemon = !(has svcRoot "nix-daemon-custom");
      noStorage = !(has svcRoot "nix-daemon-storage");
      noSocket = !(has (socketsOf hostRoot) "nix-daemon-custom");
      noGiteaBindPaths = (svcRoot."gitea-runner-default".serviceConfig.BindPaths or [ ]) == [ ];
      noGiteaDep = !(lib.elem "nix-daemon-custom.service" (svcRoot."gitea-runner-default".after or [ ]));
      noSrvMount = !(has (bindMountsOf hostRoot) "srv-nix");
    };
  };

  # --- scenario C: empty path fires the assertion -------------------------
  # NixOS turns failed assertions into a `throw`, which `tryEval` catches.
  tryEmpty = builtins.tryEval (mkHost "" { }).config.system.build.toplevel.outPath;
  scenarioEmpty = {
    name = "store.path=\"\" fires the mandatory-path assertion";
    checks = { refused = !tryEmpty.success; };
  };

  # --- scenario D: multiple instances share the relocated store -----------
  hostMulti = mkHost "/srv" {
    services.nixtache.forgejo-runner.instances = {
      default.tokenFile = runnerToken;
      test = { labels = [ "nixos:test" ]; tokenFile = runnerToken; };
    };
  };
  svcMulti = servicesOf hostMulti;
  scenarioMulti = {
    name = "instances.<name>: one gitea-runner-<name> per instance, each wired, distinct token/name/labels";
    checks = {
      hasGiteaDefault = has svcMulti "gitea-runner-default";
      hasGiteaTest = has svcMulti "gitea-runner-test";
      defaultBindPaths = svcMulti."gitea-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      testBindPaths = svcMulti."gitea-runner-test".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      defaultLabels = (instancesOf hostMulti)."default".labels == [ "nixos:host" ];
      testLabels = (instancesOf hostMulti)."test".labels == [ "nixos:test" ];
      defaultName = (instancesOf hostMulti)."default".name == "default";
      testName = (instancesOf hostMulti)."test".name == "test";
      # distinct per-instance token mounts
      defaultTokenMount = (bindMountsOf hostMulti)."forgejo-token-default".mountPoint == "/var/secrets/forgejo-runner/default/token";
      testTokenMount = (bindMountsOf hostMulti)."forgejo-token-test".mountPoint == "/var/secrets/forgejo-runner/test/token";
    };
  };

  # --- scenario E: SSH keys enabled → LoadCredential + key mounts ----------
  hostSsh = mkHost "/srv" {
    services.nixtache.forgejo-runner.secrets = {
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
  };
  svcSsh = servicesOf hostSsh;
  scenarioSsh = {
    name = "secrets.ssh* set → bot key mounts + LoadCredential wired";
    checks = {
      loadCredential = loadCred svcSsh == [
        "ssh_private:/var/secrets/forgejo-runner/ssh_host_ed25519_key"
        "ssh_public:/var/secrets/forgejo-runner/ssh_host_ed25519_key.pub"
      ];
      hasPrivateMount = (bindMountsOf hostSsh)."ssh-private-key".mountPoint == "/var/secrets/forgejo-runner/ssh_host_ed25519_key";
      hasPublicMount = (bindMountsOf hostSsh)."ssh-public-key".mountPoint == "/var/secrets/forgejo-runner/ssh_host_ed25519_key.pub";
    };
  };

  # --- scenario F: half-set SSH keys fires the assertion ------------------
  tryHalfSsh = builtins.tryEval (mkHost "/srv" {
    services.nixtache.forgejo-runner.secrets.sshPrivateKey = dummySecret;
    # sshPublicKey left null
  }).config.system.build.toplevel.outPath;
  scenarioHalfSsh = {
    name = "secrets: only one of sshPrivateKey/sshPublicKey set fires the assertion";
    checks = { refused = !tryHalfSsh.success; };
  };

  scenarios = [ scenarioSrv scenarioRoot scenarioEmpty scenarioMulti scenarioSsh scenarioHalfSsh ];

  failed = builtins.concatMap
    (s:
      if builtins.all (c: c) (builtins.attrValues s.checks)
      then [ ]
      else [ s.name ]
    )
    scenarios;

  allOk = failed == [ ];

  # Human-readable report (one line per individual check).
  report = lib.concatStringsSep "\n" (lib.flatten (map
    (s:
      [ s.name ] ++ (map
        (cn: "  ${if s.checks.${cn} then "ok  " else "FAIL"}  ${cn}")
        (builtins.attrNames s.checks))
    )
    scenarios));

  # Empty when everything passes; otherwise the failing scenario names.
  failMsg = lib.optionalString (!allOk) "FAILED: ${lib.concatStringsSep ", " failed}";

  # Storage oneshot script. `nix copy --to <store.path>` must target the base
  # (/srv), letting nix reconstruct the /nix suffix. ExecStart is a derivation
  # (writeShellScript), so its content is verified at build time below.
  storageExecSrv = svcSrv."nix-daemon-storage".serviceConfig.ExecStart;
in
pkgs.runCommand "forgejo-runner-module-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
    # Force the script into the store so the builder can inspect its text.
    deps = [ storageExecSrv ];
  }
  ''
    # Report to stdout (visible in build logs) and into $out (CI prints $out,
    # so the report shows up on cached rebuilds too).
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then
      echo
      cat "$failMsgPath"
      printf '\n%s\n' "$(<$failMsgPath)" >> "$out"
      exit 1
    fi
    # `nix copy --to` must use the relocated base, not <base>/nix.
    if ! grep -q -- '--to /srv ' "${storageExecSrv}"; then
      echo "FAIL: nix-daemon-storage ExecStart does not target the store base (/srv)"
      echo "FAIL: nix-daemon-storage ExecStart does not target the store base (/srv)" >> "$out"
      exit 1
    fi
  ''

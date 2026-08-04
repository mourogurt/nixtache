# Pure-evaluation tests for the runner module.
#
# The module is consumed by nixtache itself (dogfooding): each scenario imports
# `self.nixosModules.runner` and feeds it a per-instance `tokenFile`
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
#   - gitUser → cfg.gitUser is exported to every job as NIXTACHE_GIT_USER via
#               runner.envs (the mechanism ssh-setup / push steps rely on).
#
# Exposed via the flake as `checks.<system>.runner`.
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
  # push-back). Only `store.path` (and the `extra` module) varies.
  # stateVersion follows nixpkgs' own test convention (lib.trivial.release) so
  # the test exercises the current release, not a pinned old one.
  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    services.nixtache.runner = {
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
self.nixosModules.runner
        baseModule
        { services.nixtache.runner.store.path = storePath; }
        extra
      ];
    };

  containerCfg = host: host.config.containers."runner".config;
  servicesOf = host: (containerCfg host).systemd.services;
  socketsOf = host: (containerCfg host).systemd.sockets;
  bindMountsOf = host: host.config.containers."runner".bindMounts;
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
      tokenMount = (bindMountsOf hostSrv)."runner-token-default".mountPoint == "/var/secrets/runner/default/token";
      noFlakeSshMount = !(has (bindMountsOf hostSrv) "flake-ssh-private-key");
      noUpdateSshMount = !(has (bindMountsOf hostSrv) "update-ssh-private-key");
      noLoadCredential = loadCred svcSrv == [ ];
      # CAP_SYS_ADMIN granted so the Nix build sandbox works inside nspawn
      # (without it `nix.settings.sandbox = true` (NixOS default) fails).
      hasSandboxCap = lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities;
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
    services.nixtache.runner.instances = {
      default.tokenFile = runnerToken;
      test = { labels = [ "test:host" ]; tokenFile = runnerToken; };
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
      testLabels = (instancesOf hostMulti)."test".labels == [ "test:host" ];
      defaultName = (instancesOf hostMulti)."default".name == "default";
      testName = (instancesOf hostMulti)."test".name == "test";
      # distinct per-instance token mounts
      defaultTokenMount = (bindMountsOf hostMulti)."runner-token-default".mountPoint == "/var/secrets/runner/default/token";
      testTokenMount = (bindMountsOf hostMulti)."runner-token-test".mountPoint == "/var/secrets/runner/test/token";
    };
  };

  # --- scenario E: flake + update sshCreds → both LoadCredentials mounted ---
  hostSsh = mkHost "/srv" {
    services.nixtache.runner.flakeSshCreds = {
      user = "forgejo";
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
    services.nixtache.runner.updateSshCreds = {
      user = "forgejo";
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
  };
  svcSsh = servicesOf hostSsh;
  scenarioSsh = {
    name = "flakeSshCreds + updateSshCreds → both LoadCredentials + mounts wired";
    checks = {
      loadCredential = loadCred svcSsh == [
        "flake_ssh_private:/var/secrets/runner/flake_ssh_key"
        "flake_ssh_public:/var/secrets/runner/flake_ssh_key.pub"
        "update_ssh_private:/var/secrets/runner/update_ssh_key"
        "update_ssh_public:/var/secrets/runner/update_ssh_key.pub"
      ];
      hasFlakeMount = (bindMountsOf hostSsh)."flake-ssh-private-key".mountPoint == "/var/secrets/runner/flake_ssh_key";
      hasUpdateMount = (bindMountsOf hostSsh)."update-ssh-private-key".mountPoint == "/var/secrets/runner/update_ssh_key";
    };
  };

  # --- scenario F: only flakeSshCreds → flake-only LoadCredential ----------
  hostFlakeOnly = mkHost "/srv" {
    services.nixtache.runner.flakeSshCreds = {
      user = "git";
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
    # updateSshCreds left null → no update_* LoadCredential, update user empty
  };
  envsFlakeOnly = (instancesOf hostFlakeOnly)."default".settings.runner.envs;
  scenarioFlakeOnly = {
    name = "only flakeSshCreds set → flake LoadCredential only, update user empty";
    checks = {
      hasFlakeCred = lib.elem "flake_ssh_private:/var/secrets/runner/flake_ssh_key" (loadCred (servicesOf hostFlakeOnly));
      noUpdateCred = !(lib.elem "update_ssh_private:/var/secrets/runner/update_ssh_key" (loadCred (servicesOf hostFlakeOnly)));
      flakeUser = envsFlakeOnly.NIXTACHE_FLAKE_GIT_USER == "git";
      updateUserEmpty = envsFlakeOnly.NIXTACHE_UPDATE_GIT_USER == "";
    };
  };

  # --- scenario G: sshCreds users + bot identity exported via runner.envs --
  hostEnvs = mkHost "/srv" {
    services.nixtache.runner.flakeSshCreds = {
      user = "forgejo";
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
    services.nixtache.runner.updateSshCreds = {
      user = "forgejo";
      sshPrivateKey = dummySecret;
      sshPublicKey = dummySecret;
    };
    services.nixtache.runner.bot.email = "ci@example.com";
  };
  envsOf = (instancesOf hostEnvs)."default".settings.runner.envs;
  scenarioEnvs = {
    name = "sshCreds users + bot identity exported to jobs via runner.envs";
    checks = {
      flakeUser = envsOf.NIXTACHE_FLAKE_GIT_USER == "forgejo";
      updateUser = envsOf.NIXTACHE_UPDATE_GIT_USER == "forgejo";
      botName = envsOf.NIXTACHE_BOT_NAME == "fbot";
      botEmail = envsOf.NIXTACHE_BOT_EMAIL == "ci@example.com";
      # enableSandbox defaults to true → HAS_SANDBOX_CAP=1 exported to jobs.
      hasSandboxEnv = envsOf.HAS_SANDBOX_CAP == "1";
    };
  };

  # --- scenario H: enableSandbox=true (default) + additionalCapabilities merge
  # Symmetric counterpart to scenarioNoSandbox: with the default (sandbox on),
  # CAP_SYS_ADMIN is granted, the daemon sandbox stays on, HAS_SANDBOX_CAP=1 is
  # exported, AND consumer-supplied additionalCapabilities merge on top.
  hostSandboxOn = mkHost "/srv" {
    services.nixtache.runner.additionalCapabilities = [ "CAP_NET_ADMIN" ];
  };
  scenarioSandboxOn = {
    name = "enableSandbox=true (default): CAP_SYS_ADMIN granted, daemon sandbox on, HAS_SANDBOX_CAP=1, extra caps merged";
    checks = {
      hasSysAdmin = lib.elem "CAP_SYS_ADMIN" hostSandboxOn.config.containers."runner".additionalCapabilities;
      hasExtraCap = lib.elem "CAP_NET_ADMIN" hostSandboxOn.config.containers."runner".additionalCapabilities;
      daemonSandboxOn = (containerCfg hostSandboxOn).nix.settings.sandbox == true;
      sandboxEnvOn = (instancesOf hostSandboxOn)."default".settings.runner.envs.HAS_SANDBOX_CAP == "1";
    };
  };

  # --- scenario I: enableSandbox=false keeps the container unprivileged -----
  # No CAP_SYS_ADMIN, daemon sandbox forced off, and HAS_SANDBOX_CAP=0 so the
  # reusable CI actions fall back to --no-sandbox. Consumer-supplied
  # additionalCapabilities still merge through.
  hostNoSandbox = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
    services.nixtache.runner.additionalCapabilities = [ "CAP_NET_ADMIN" ];
  };
  scenarioNoSandbox = {
    name = "enableSandbox=false: no CAP_SYS_ADMIN, daemon sandbox off, HAS_SANDBOX_CAP=0, extra caps preserved";
    checks = {
      noSysAdmin = !(lib.elem "CAP_SYS_ADMIN" hostNoSandbox.config.containers."runner".additionalCapabilities);
      hasExtraCap = lib.elem "CAP_NET_ADMIN" hostNoSandbox.config.containers."runner".additionalCapabilities;
      daemonSandboxOff = (containerCfg hostNoSandbox).nix.settings.sandbox == false;
      sandboxEnvOff = (instancesOf hostNoSandbox)."default".settings.runner.envs.HAS_SANDBOX_CAP == "0";
    };
  };

  scenarios = [ scenarioSrv scenarioRoot scenarioEmpty scenarioMulti scenarioSsh scenarioFlakeOnly scenarioEnvs scenarioSandboxOn scenarioNoSandbox ];

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
pkgs.runCommand "runner-module-test"
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

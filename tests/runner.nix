# Pure-evaluation tests for the runner module.
#
# The module is consumed by nixtache itself (dogfooding): each scenario imports
# `self.nixosModules.runner` and feeds it a per-instance `tokenFile`. These
# checks verify the module WIRING without running any container/VM — the
# module only forwards `tokenFile` as a bind-mount hostPath at eval time and
# never reads its content, so a dummy path exercises the wiring exactly like
# a real consumer's secret path would (a live deployment decrypts the real
# token via the consumer's secret backend first).
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
  # Used for every secret-shaped option (token, SSH keys, cache key) — the
  # repository deliberately stores no secrets, not even encrypted ones.
  dummySecret = /dev/null;

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
      instances.default.tokenFile = dummySecret;
      secrets.cachePrivateKey = dummySecret;
      # enableSandbox is NOT set here — each scenario that asserts on sandbox
      # state sets it explicitly (tests must not rely on the nixtache default).
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
  # enableSandbox explicit (asserts on the cap below) — tests must not rely on
  # the nixtache default.
  hostSrv = mkHost "/srv" { services.nixtache.runner.enableSandbox = false; };
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
      # clone on a nix-enabled container: storage seeds through the system daemon
      storageRequiresSystemDaemon = lib.elem "nix-daemon.service" (svcSrv."nix-daemon-storage".requires or [ ]);
      storageDaemonEnv = lib.elem "NIX_REMOTE=daemon" (svcSrv."nix-daemon-storage".serviceConfig.Environment or [ ]);
      socketPath = (socketsOf hostSrv)."nix-daemon-custom".listenStreams == [ "/srv/nix/var/nix/daemon-socket/socket" ];
      srvMountPoint = (bindMountsOf hostSrv)."srv-nix".mountPoint == "/srv";
      # per-instance token mount present, SSH mounts / LoadCredential absent
      tokenMount = (bindMountsOf hostSrv)."runner-token-default".mountPoint == "/var/secrets/runner/default/token";
      noFlakeSshMount = !(has (bindMountsOf hostSrv) "flake-ssh-private-key");
      noUpdateSshMount = !(has (bindMountsOf hostSrv) "update-ssh-private-key");
      noLoadCredential = loadCred svcSrv == [ ];
      # enableSandbox=false (explicit in baseModule) → no CAP_SYS_ADMIN granted
      # (the container stays unprivileged; sandbox is off). The sandbox-ON path
      # is covered by scenarioSandboxOn.
      noSandboxCap = !(lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities);
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
      default.tokenFile = dummySecret;
      test = { labels = [ "test:host" ]; tokenFile = dummySecret; };
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
  # enableSandbox explicit (asserts HAS_SANDBOX_CAP below).
  hostEnvs = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
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
      # enableSandbox=false (explicit in baseModule) → HAS_SANDBOX_CAP=0.
      hasSandboxEnv = envsOf.HAS_SANDBOX_CAP == "0";
    };
  };

  # --- scenario H: enableSandbox=true (explicit) + additionalCapabilities merge
  # Symmetric counterpart to scenarioNoSandbox: with sandbox explicitly ON,
  # CAP_SYS_ADMIN is granted, the daemon sandbox stays on, HAS_SANDBOX_CAP=1 is
  # exported, AND consumer-supplied additionalCapabilities merge on top. NB:
  # enableSandbox is set explicitly here because the default is `false` (sandbox
  # in nspawn is unreliable — see sandbox.nix).
  hostSandboxOn = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = true;
    services.nixtache.runner.additionalCapabilities = [ "CAP_NET_ADMIN" ];
  };
  scenarioSandboxOn = {
    name = "enableSandbox=true (explicit): CAP_SYS_ADMIN, sandbox on, HAS_SANDBOX_CAP=1, /proc fix on BOTH daemons";
    checks = {
      hasSysAdmin = lib.elem "CAP_SYS_ADMIN" hostSandboxOn.config.containers."runner".additionalCapabilities;
      hasExtraCap = lib.elem "CAP_NET_ADMIN" hostSandboxOn.config.containers."runner".additionalCapabilities;
      daemonSandboxOn = (containerCfg hostSandboxOn).nix.settings.sandbox == true;
      sandboxEnvOn = (instancesOf hostSandboxOn)."default".settings.runner.envs.HAS_SANDBOX_CAP == "1";
      # /proc locked-mount fix (nixpkgs#405256): the system daemon's ExecStart
      # is wrapped — the daemon's own exec chain unshares a mount namespace and
      # remounts /proc (an ExecStartPre mount would not reach it: systemd clones
      # the mount namespace per Exec* command). The override is a list whose
      # first empty entry clears the package-supplied ExecStart.
      nixDaemonWrapped =
        let es = (servicesOf hostSandboxOn)."nix-daemon".serviceConfig.ExecStart or [ ];
        in lib.isList es && lib.any (lib.hasInfix "nix-daemon-fresh-proc") es;
      # …and the relocated-store daemon (store.path="/srv" → nix-daemon-custom
      # exists; CI builds go through it, so it needs the same fix). Its ExecStart
      # is owned by store.nix and stays a single string there.
      hasCustomDaemon = has (servicesOf hostSandboxOn) "nix-daemon-custom";
      customDaemonWrapped =
        lib.hasInfix "nix-daemon-custom-fresh-proc"
          ((servicesOf hostSandboxOn)."nix-daemon-custom".serviceConfig.ExecStart or "");
    };
  };

  # --- scenario I: enableSandbox=false (explicit) keeps the container unprivileged
  # No CAP_SYS_ADMIN, daemon sandbox forced off, and HAS_SANDBOX_CAP=0 so the
  # reusable CI actions fall back to --no-sandbox. Consumer-supplied
  # additionalCapabilities still merge through. (Explicit `false` here even
  # though baseModule already sets it — the scenario tests this path, so be
  # self-documenting; tests must not rely on defaults.)
  hostNoSandbox = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
    services.nixtache.runner.additionalCapabilities = [ "CAP_NET_ADMIN" ];
  };
  scenarioNoSandbox = {
    name = "enableSandbox=false (explicit): no CAP_SYS_ADMIN, daemon sandbox off, HAS_SANDBOX_CAP=0, extra caps preserved";
    checks = {
      noSysAdmin = !(lib.elem "CAP_SYS_ADMIN" hostNoSandbox.config.containers."runner".additionalCapabilities);
      hasExtraCap = lib.elem "CAP_NET_ADMIN" hostNoSandbox.config.containers."runner".additionalCapabilities;
      daemonSandboxOff = (containerCfg hostNoSandbox).nix.settings.sandbox == false;
      sandboxEnvOff = (instancesOf hostNoSandbox)."default".settings.runner.envs.HAS_SANDBOX_CAP == "0";
      # no /proc wrapper on either daemon (their ExecStart stay untouched)
      nixDaemonNotWrapped =
        !lib.hasInfix "fresh-proc"
          (toString ((servicesOf hostNoSandbox)."nix-daemon".serviceConfig.ExecStart or ""));
      customDaemonNotWrapped =
        !lib.hasInfix "fresh-proc"
          ((servicesOf hostNoSandbox)."nix-daemon-custom".serviceConfig.ExecStart or "");
    };
  };

  # --- deploy map scenarios (Batch A: services.nixtache.runner.deploy.targets)
  # Base host has no targets → NIXTACHE_DEPLOY_TARGETS="{}" (empty map), no
  # deploy bind-mounts, no deploy LoadCredential on the runner service.
  envsNoTargets = (instancesOf hostSrv)."default".settings.runner.envs;
  scenarioNoTargets = {
    name = "deploy.targets empty → NIXTACHE_DEPLOY_TARGETS=\"{}\", no deploy mounts/creds";
    checks = {
      emptyMapEnv = envsNoTargets.NIXTACHE_DEPLOY_TARGETS or null == "{}";
      noDeployMount = !(has (bindMountsOf hostSrv) "deploy_ssh_default");
      noDeployCred =
        !(lib.elem "deploy_ssh_default:/var/secrets/runner/deploy/default/id_ed25519"
          (loadCred svcSrv));
    };
  };

  # Two targets WITH keys → both serialised (hasKey=true), 2 bind-mounts +
  # per-service LoadCredential. buildHost MUST be absent (S4).
  hostTargets = mkHost "/srv" {
    services.nixtache.runner.deploy.targets = {
      desktop = {
        host = "10.13.37.3";
        sshUser = "nixos-deploy";
        sshPrivateKey = dummySecret;
        tags = [ "lan" "vpn" ];
      };
      laptop = {
        host = "10.13.37.2";
        sshUser = "nixos-deploy";
        sshPrivateKey = dummySecret;
        minFreeBytes = 123456789;
      };
    };
  };
  svcTargets = servicesOf hostTargets;
  envsTargets = (instancesOf hostTargets)."default".settings.runner.envs;
  parsedTargets = builtins.fromJSON envsTargets.NIXTACHE_DEPLOY_TARGETS;
  scenarioTargets = {
    name = "deploy.targets with keys → env JSON has both (hasKey=true), 2 mounts + LoadCreds, no buildHost";
    checks = {
      hasDesktop = parsedTargets ? desktop;
      hasLaptop = parsedTargets ? laptop;
      desktopHasKey = parsedTargets.desktop.hasKey == true;
      desktopHost = parsedTargets.desktop.host == "10.13.37.3";
      desktopTags = parsedTargets.desktop.tags == [ "lan" "vpn" ];
      noBuildHostDesktop = !(parsedTargets.desktop ? buildHost);
      # minFreeBytes preset ships in the env JSON: default 5 GiB, custom round-trips
      desktopMinFreeDefault = parsedTargets.desktop.minFreeBytes == 5 * 1024 * 1024 * 1024;
      laptopMinFreeCustom = parsedTargets.laptop.minFreeBytes == 123456789;
      # secret path must NOT leak into the env JSON
      noSecretLeak = !(builtins.elem (toString dummySecret)
        (lib.concatLists (map (t: builtins.attrValues t) (builtins.attrValues parsedTargets))));
      desktopMount = (bindMountsOf hostTargets)."deploy_ssh_desktop".mountPoint == "/var/secrets/runner/deploy/desktop/id_ed25519";
      laptopMount = (bindMountsOf hostTargets)."deploy_ssh_laptop".mountPoint == "/var/secrets/runner/deploy/laptop/id_ed25519";
      desktopMountHostPath = (bindMountsOf hostTargets)."deploy_ssh_desktop".hostPath == toString dummySecret;
      desktopMountReadOnly = (bindMountsOf hostTargets)."deploy_ssh_desktop".isReadOnly == true;
      hasDesktopCred = lib.elem "deploy_ssh_desktop:/var/secrets/runner/deploy/desktop/id_ed25519" (loadCred svcTargets);
      hasLaptopCred = lib.elem "deploy_ssh_laptop:/var/secrets/runner/deploy/laptop/id_ed25519" (loadCred svcTargets);
    };
  };

  # sshPrivateKey=null → hasKey:false in env, NO bind-mount, NO LoadCredential
  # (target declared but no credential → action skips it, R1 optionality).
  hostNoKey = mkHost "/srv" {
    services.nixtache.runner.deploy.targets.keyless = {
      host = "10.13.37.9";
      sshUser = "nixos-deploy";
      # sshPrivateKey omitted → null
    };
  };
  svcNoKey = servicesOf hostNoKey;
  parsedNoKey = builtins.fromJSON
    ((instancesOf hostNoKey)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS);
  scenarioNoKey = {
    name = "deploy.targets.<name> with sshPrivateKey=null → hasKey=false, no mount/cred";
    checks = {
      hasKeyless = parsedNoKey ? keyless;
      keylessHasKeyFalse = parsedNoKey.keyless.hasKey == false;
      noKeylessMount = !(has (bindMountsOf hostNoKey) "deploy_ssh_keyless");
      noKeylessCred = !(lib.elem "deploy_ssh_keyless:/var/secrets/runner/deploy/keyless/id_ed25519" (loadCred svcNoKey));
    };
  };

  # minFreeBytes = 0 (pre-copy check disabled) serialises intact — the action
  # reads 0 as "no free-space query for this target".
  hostMinFreeZero = mkHost "/srv" {
    services.nixtache.runner.deploy.targets.ungated = {
      host = "10.13.37.10";
      sshPrivateKey = dummySecret;
      minFreeBytes = 0;
    };
  };
  parsedMinFreeZero = builtins.fromJSON
    ((instancesOf hostMinFreeZero)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS);
  scenarioMinFreeZero = {
    name = "deploy.targets.<name>.minFreeBytes=0 → 0 ships in env JSON (check disabled)";
    checks = {
      zeroShips = parsedMinFreeZero.ungated.minFreeBytes == 0;
    };
  };

  # method="ab-image" serialises correctly; the action's ab-image branch is
  # Batch E — here we only assert the field reaches the env intact.
  hostAbImage = mkHost "/srv" {
    services.nixtache.runner.deploy.targets.server = {
      host = "10.13.37.1";
      sshUser = "nixos-deploy";
      sshPrivateKey = dummySecret;
      method = "ab-image";
    };
  };
  parsedAb = builtins.fromJSON
    ((instancesOf hostAbImage)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS);
  scenarioAbImage = {
    name = "deploy.targets.<name>.method=\"ab-image\" → field in env JSON intact";
    checks = {
      abMethod = parsedAb.server.method == "ab-image";
      abHasKey = parsedAb.server.hasKey == true;
      # transport field MUST be absent (removed in V2 — single activation path).
      noTransport = !(parsedAb.server ? transport);
    };
  };

  # method defaults to "live" (V2: was "deploy-rs"); assert the default +
  # transport is gone from a default-target entry too.
  parsedDefault = parsedTargets.desktop;
  scenarioLiveDefault = {
    name = "deploy.targets.<name>.method defaults to \"live\"; transport field absent";
    checks = {
      liveDefault = parsedDefault.method == "live";
      noTransport = !(parsedDefault ? transport);
    };
  };

  # _extraRunnerEnvs aggregator proof: NIXTACHE_DEPLOY_TARGETS flows from
  # deploy.nix → instances.nix envs (the S1 refactor). Covered structurally by
  # the scenarios above (they read it from instancesOf.*.envs), but assert it
  # explicitly once.
  scenarioExtraEnvsAggregated = {
    name = "_extraRunnerEnvs aggregator: deploy.nix key reaches runner.envs (S1)";
    checks = {
      envKeyPresent = envsTargets ? NIXTACHE_DEPLOY_TARGETS;
    };
  };

  # --- module↔action contract scenarios (map serialization vs action filters)
  # `enable` and `extraOptions` MUST ship in the env JSON — the action's
  # optionality filters read both (the absence of `enable` once made every
  # target skip in production while hand-crafted test JSON masked it).
  hostContract = mkHost "/srv" {
    services.nixtache.runner.deploy.targets = {
      desktop = {
        host = "10.13.37.3";
        sshUser = "nixos-deploy";
        sshPrivateKey = dummySecret;
        sshPublicKey = dummySecret;
        extraOptions = [ "--no-substitute-on-target" ];
        tags = [ "lan" ];
      };
      disabled = {
        host = "10.13.37.4";
        sshUser = "nixos-deploy";
        sshPrivateKey = dummySecret;
        enable = false;
      };
      keyless = {
        host = "10.13.37.9";
        sshUser = "nixos-deploy";
      };
    };
  };
  parsedContract = builtins.fromJSON
    ((instancesOf hostContract)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS);
  scenarioMapContract = {
    name = "map serialization: enable + extraOptions + timeout + pub-key wiring all ship";
    checks = {
      desktopEnable = parsedContract.desktop.enable == true;
      desktopExtraOptions = parsedContract.desktop.extraOptions == [ "--no-substitute-on-target" ];
      disabledEnableFalse = parsedContract.disabled.enable == false;
      keylessEnableTrue = parsedContract.keyless.enable == true;
      timeoutShips = parsedContract.desktop.timeout == 240;
      # sshPublicKey → bind-mount + LoadCredential deploy_ssh_<name>.pub
      pubMount = (bindMountsOf hostContract)."deploy_ssh_desktop-pub".mountPoint == "/var/secrets/runner/deploy/desktop/id_ed25519.pub";
      pubMountHostPath = (bindMountsOf hostContract)."deploy_ssh_desktop-pub".hostPath == toString dummySecret;
      pubCred = lib.elem "deploy_ssh_desktop.pub:/var/secrets/runner/deploy/desktop/id_ed25519.pub"
        (loadCred (servicesOf hostContract));
    };
  };

  # The env JSON the contract harness (bottom of this file) feeds to the REAL
  # action script — generated by the REAL module, never hand-written.
  contractMapEnv = (instancesOf hostContract)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS;

  # Batch F minimum: a declared non-x86_64 system serializes intact.
  hostAarch64 = mkHost "/srv" {
    services.nixtache.runner.deploy.targets.rpi = {
      host = "10.13.37.7";
      sshUser = "nixos-deploy";
      sshPrivateKey = dummySecret;
      system = "aarch64-linux";
    };
  };
  parsedAarch64 = builtins.fromJSON
    ((instancesOf hostAarch64)."default".settings.runner.envs.NIXTACHE_DEPLOY_TARGETS);
  scenarioAarch64 = {
    name = "deploy.targets.<name>.system=\"aarch64-linux\" → field ships in env JSON";
    checks = {
      aarch64System = parsedAarch64.rpi.system == "aarch64-linux";
      aarch64HasKey = parsedAarch64.rpi.hasKey == true;
    };
  };

  # --- ab-image staging scenarios (Batch E: services.nixtache.runner.deploy.ab)
  # ab.enable=true wires the central staging store: bind-mount into the
  # container, nginx location on the cache vhost, runner-host/staging envs, the
  # retain-GC timer+service, gnupg in the container, and (when a signing key is
  # supplied) a LoadCredential on every gitea-runner service.
  hostAb = mkHost "/srv" {
    services.nixtache.runner.deploy.ab = {
      enable = true;
      runnerHost = "bincache.test";
      signingKeyFile = dummySecret;
    };
  };
  envsAb = (instancesOf hostAb)."default".settings.runner.envs;
  scenarioAbStage = {
    name = "deploy.ab.enable=true → staging bind-mount + nginx autoindex location + envs + gc + gnupg";
    checks = {
      # central staging dir bind-mounted into the container (rw)
      stageMount = (bindMountsOf hostAb)."ab-stage".hostPath == "/var/lib/nixtache/ab-stage";
      stageMountPoint = (bindMountsOf hostAb)."ab-stage".mountPoint == "/var/lib/nixtache/ab-stage";
      stageMountRW = (bindMountsOf hostAb)."ab-stage".isReadOnly == false;
      # staging dir created on the host via tmpfiles
      stageTmpfiles = lib.any (r: lib.hasInfix "/var/lib/nixtache/ab-stage" r) hostAb.config.systemd.tmpfiles.rules;
      # nginx serves the staging store on the cache vhost with autoindex on
      nginxLocation = hostAb.config.services.nginx.virtualHosts."bincache.test".locations ? "/ab-stage/";
      nginxAutoindex = lib.hasInfix "autoindex on"
        (hostAb.config.services.nginx.virtualHosts."bincache.test".locations."/ab-stage/".extraConfig or "");
      # runner-host identity + staging destination exported to every job
      envRunnerHost = envsAb.NIXTACHE_RUNNER_HOST == "bincache.test";
      envAbStage = envsAb.NIXTACHE_AB_STAGE == "/var/lib/nixtache/ab-stage";
      # retain-GC timer + service present on the host
      hasAbGcService = hostAb.config.systemd.services ? "nixtache-ab-gc";
      hasAbGcTimer = hostAb.config.systemd.timers ? "nixtache-ab-gc";
      # gnupg available in the container (the action signs SHA256SUMS with it)
      gnupgInContainer = lib.any (p: lib.hasInfix "gnupg" (p.name or ""))
        (containerCfg hostAb).environment.systemPackages;
      # GPG signing key exposed via LoadCredential on the runner service
      hasSigningCred = lib.hasPrefix "sysupdate_signing_key:"
        (lib.concatStringsSep "," (loadCred (servicesOf hostAb)));
    };
  };

  # forgejoPort default parses the port out of forgejoUrl (S2). baseModule uses
  # "http://localhost:3000" → 3000.
  scenarioForgejoPort = {
    name = "runner.forgejoPort default = port parsed from forgejoUrl (3000 here, S2)";
    checks = {
      forgejoPort3000 = hostAb.config.services.nixtache.runner.forgejoPort == 3000;
    };
  };

  # ab.enable=true with a custom stagingPath whose basename matches the default
  # nginx.location basename → fine. Mismatched basename → eval refuses.
  hostAbMismatch = mkHost "/srv" {
    services.nixtache.runner.deploy.ab = {
      enable = true;
      runnerHost = "bincache.test";
      stagingPath = "/var/lib/nixtache/elsewhere"; # basename "elsewhere" ≠ "ab-stage"
    };
  };
  tryAbMismatch = builtins.tryEval hostAbMismatch.config.system.build.toplevel.outPath;
  scenarioAbBasenameAssert = {
    name = "deploy.ab: stagingPath basename ≠ nginx.location basename → eval refuses";
    checks = { refused = !tryAbMismatch.success; };
  };

  # --- scenario J: clone on an appliance-style container (nix.enable=false) --
  # On an A/B appliance there is no system nix-daemon, so nix-daemon-storage
  # must not require it and must clone from the local store directly (no
  # NIX_REMOTE=daemon), while nix-daemon-custom runs standalone (spec §11.3).
  hostApplianceClone = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
    containers.runner.config = {
      nix.enable = false;
      # nixpkgs asserts nix.gc.automatic → nix.enable, so the GC timer goes
      # with the daemon.
      nix.gc.automatic = false;
    };
  };
  svcAppliance = servicesOf hostApplianceClone;
  scenarioApplianceClone = {
    name = "clone on appliance container (nix.enable=false): storage standalone, custom daemon standalone (§11.3)";
    checks = {
      hasStorage = has svcAppliance "nix-daemon-storage";
      storageNoRequires = (svcAppliance."nix-daemon-storage".requires or [ ]) == [ ];
      storageNoDaemonEnv = !(lib.elem "NIX_REMOTE=daemon"
        (svcAppliance."nix-daemon-storage".serviceConfig.Environment or [ ]));
      noSystemDaemon = !(has svcAppliance "nix-daemon");
      hasCustomDaemon = has svcAppliance "nix-daemon-custom";
      customDaemonStandalone =
        (svcAppliance."nix-daemon-custom".requires or [ ]) == [ "nix-daemon-storage.service" ];
      # No nixbld build users exist without the system nix module — the
      # daemon builds as root via NIX_CONF.
      customDaemonBuildsAsRoot =
        lib.hasInfix "build-users-group ="
          (svcAppliance."nix-daemon-custom".environment.NIX_CONF or "");
    };
  };

  # --- scenario: gitHost → NIXTACHE_GIT_SSH_HOST env + known_hosts ---------
  # The FIRST hostName is the canonical SSH endpoint exported to every job as
  # NIXTACHE_GIT_SSH_HOST (update-flake push target). gitHost=null (hostSrv)
  # must NOT export it.
  hostGitHost = mkHost "/srv" {
    services.nixtache.runner.gitHost = {
      name = "git_ed25519";
      hostNames = [ "git.example.com" "10.0.0.1" "localhost" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForEvalOnlyTests0000000000000000";
    };
  };
  envsGitHost = (instancesOf hostGitHost)."default".settings.runner.envs;
  scenarioGitSshHost = {
    name = "gitHost → NIXTACHE_GIT_SSH_HOST env (hostNames[0]) + known_hosts entry";
    checks = {
      sshHostEnv = envsGitHost.NIXTACHE_GIT_SSH_HOST == "git.example.com";
      knownHostEntry =
        (containerCfg hostGitHost).services.openssh.knownHosts."git_ed25519".hostNames
        == [ "git.example.com" "10.0.0.1" "localhost" ];
      noEnvWhenNull = !(envsNoTargets ? NIXTACHE_GIT_SSH_HOST);
    };
  };

  # --- scenario: container resource limits (host-side serviceConfig) -------
  # Default budget targets a host shared with other services (16G/14G); the
  # swap/CPU/IO knobs stay ABSENT from the unit when null (host systemd policy
  # applies) and pass through verbatim when set. Asserts on the host-side
  # `container@runner` unit, not the container's inner config.
  resOf = host: host.config.systemd.services."container@runner".serviceConfig;
  hostResCustom = mkHost "/" {
    services.nixtache.runner = {
      memoryMax = "32G";
      memoryHigh = "30G";
      memorySwapMax = "8G";
      cpuWeight = 200;
      ioWeight = 50;
    };
  };
  scenarioResources = {
    name = "container resources: shared-host defaults; swap/cpu/io knobs omitted when null, pass through when set";
    checks = {
      defaultMax = (resOf hostRoot).MemoryMax == "16G";
      defaultHigh = (resOf hostRoot).MemoryHigh == "14G";
      noSwapDefault = !(has (resOf hostRoot) "MemorySwapMax");
      noCpuWeightDefault = !(has (resOf hostRoot) "CPUWeight");
      noIoWeightDefault = !(has (resOf hostRoot) "IOWeight");
      customMax = (resOf hostResCustom).MemoryMax == "32G";
      customHigh = (resOf hostResCustom).MemoryHigh == "30G";
      customSwap = (resOf hostResCustom).MemorySwapMax == "8G";
      customCpuWeight = (resOf hostResCustom).CPUWeight == 200;
      customIoWeight = (resOf hostResCustom).IOWeight == 50;
    };
  };

  scenarios = [
    scenarioSrv
    scenarioRoot
    scenarioEmpty
    scenarioMulti
    scenarioSsh
    scenarioFlakeOnly
    scenarioEnvs
    scenarioSandboxOn
    scenarioNoSandbox
    scenarioNoTargets
    scenarioTargets
    scenarioNoKey
    scenarioMinFreeZero
    scenarioAbImage
    scenarioLiveDefault
    scenarioExtraEnvsAggregated
    scenarioMapContract
    scenarioAarch64
    scenarioAbStage
    scenarioForgejoPort
    scenarioAbBasenameAssert
    scenarioApplianceClone
    scenarioGitSshHost
    scenarioResources
  ];

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

  # The REAL deploy-target action script, extracted from action.yml at build
  # time (same technique as the ab-deploy VM suites — the YAML is the single
  # source of the deploy logic).
  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;
in
pkgs.runCommand "runner-module-test"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pyyaml ]))
      pkgs.jq
      pkgs.bash
    ];
    inherit report failMsg;
    deployMap = contractMapEnv;
    actionYmlFileSrc = actionYmlFile;
    passAsFile = [ "report" "failMsg" "deployMap" ];
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

    # ── module→action CONTRACT RUN ─────────────────────────────────────────
    # Drives the REAL action.yml script against the env JSON generated by the
    # REAL runner module (deployMap above — never hand-crafted), with stub
    # nix/ssh. Proves the filter contract end-to-end: enable/extraOptions/
    # hasKey as serialized by the module are what the action actually reads.
    work=$(mktemp -d)
    mkdir -p "$work/fakebin" "$work/cred" "$work/run"

    # stub `nix`: flake show lists the 3 configs; build yields a fake path;
    # path-info answers the pre-copy disk check (remote inventory → empty
    # store, local closure → the fake path with a tiny narSize); anything
    # else (notably `nix copy`) succeeds.
    cat > "$work/fakebin/nix" <<'NIXEOF'
    #!/bin/sh
    if [ "$1" = "flake" ] && [ "$2" = "show" ]; then
      echo '{"nixosConfigurations":{"desktop":{},"disabled":{},"keyless":{}}}'
      exit 0
    fi
    if [ "$1" = "build" ]; then
      echo "/nix/store/0000000000000000000000000000000-fake-toplevel"
      exit 0
    fi
    if [ "$1" = "path-info" ]; then
      case "$*" in
        *--all*) : ;;  # empty remote store inventory
        *) echo "/nix/store/0000000000000000000000000000000-fake-toplevel 1000" ;;
      esac
      exit 0
    fi
    exit 0
    NIXEOF
    chmod +x "$work/fakebin/nix"

    # stub `ssh`: the probe / copy-channel / triggers all succeed; the
    # pre-copy free-space query answers with ~93 GiB.
    cat > "$work/fakebin/ssh" <<'SSHEOF'
    #!/bin/sh
    case "$*" in
      *"df -B1 --output=avail /nix/store"*) echo 99999999999 ;;
    esac
    exit 0
    SSHEOF
    chmod +x "$work/fakebin/ssh"

    # fake deploy credentials for the two keyed targets (content irrelevant).
    : > "$work/cred/deploy_ssh_desktop"
    : > "$work/cred/deploy_ssh_disabled"

    # extract the composite step's run: block from the real action.yml
    python3 - "$actionYmlFileSrc" "$work/action.sh" <<'PYEOF'
    import sys, yaml
    with open(sys.argv[1]) as f:
        a = yaml.safe_load(f)
    run = next(s["run"] for s in a["runs"]["steps"] if "run" in s)
    with open(sys.argv[2], "w") as f:
        f.write(run)
    PYEOF

    out_log="$work/action-out.log"
    set +e
    (
      cd "$work/run" || exit 1
      export PATH="$work/fakebin:$PATH"
      export GITHUB_EVENT_NAME=push
      export GITHUB_REF=refs/heads/main
      export SANDBOX_OK=0
      export NIXTACHE_DEPLOY_TARGETS="$(cat "$deployMapPath")"
      export CREDENTIALS_DIRECTORY="$work/cred"
      bash "$work/action.sh"
    ) > "$out_log" 2>&1
    run_rc=$?
    set -e
    if [ "$run_rc" -ne 0 ]; then
      echo "FAIL: module→action contract run exited $run_rc — action log:"
      sed -n '1,60p' "$out_log"
      echo "FAIL: module→action contract run exited $run_rc" >> "$out"
      exit 1
    fi
    combined="$out_log $work/run/artifacts/*.log"

    contract_fail=""
    # disabled target: serialized enable=false → skipped BY NAME
    grep -q "skip: disabled enable=false" $combined || contract_fail="$contract_fail missing-skip-disabled"
    # keyless target: hasKey=false → skipped
    grep -q "skip: keyless has no deploy key" $combined || contract_fail="$contract_fail missing-skip-keyless"
    # desktop: MUST pass the enable filter (the bug this harness guards against)
    if grep -q "skip: desktop" $combined; then contract_fail="$contract_fail desktop-skipped"; fi
    # …and complete the live path (switch mode): activated marker in its log
    grep -q "desktop: activated /nix/store/0000000000000000000000000000000-fake-toplevel" $combined \
      || contract_fail="$contract_fail desktop-not-activated"
    # structural: the remote ab trigger uses the -reboot variant; the per-target
    # timeout wrap is present; dry-activate is V2-native (pending-dry trigger,
    # NO nixos-rebuild anywhere in the action).
    grep -q "systemd-sysupdate-reboot.service" "$work/action.sh" || contract_fail="$contract_fail no-reboot-trigger"
    grep -q 'timeout "''${tmo}m"' "$work/action.sh" || contract_fail="$contract_fail no-timeout-wrap"
    grep -q "pending-dry && systemctl start nixtache-apply-dry.service" "$work/action.sh" \
      || contract_fail="$contract_fail no-dry-trigger"
    if grep -q "nixos-rebuild" "$work/action.sh"; then contract_fail="$contract_fail legacy-nixos-rebuild"; fi

    if [ -n "$contract_fail" ]; then
      echo "FAIL: module→action contract:$contract_fail"
      sed -n '1,40p' "$out_log"
      echo "FAIL: module→action contract:$contract_fail" >> "$out"
      exit 1
    fi
    echo "contract: module env ↔ action filters OK"
    rm -rf "$work"
  ''

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
      # /proc locked-mount fix (nixpkgs#405256): PrivateMounts on the system daemon…
      nixDaemonPrivateMounts = (servicesOf hostSandboxOn)."nix-daemon".serviceConfig.PrivateMounts or false == true;
      # …and on the relocated-store daemon (store.path="/srv" → nix-daemon-custom
      # exists; CI builds go through it, so it needs the same fix):
      hasCustomDaemon = has (servicesOf hostSandboxOn) "nix-daemon-custom";
      customDaemonPrivateMounts = (servicesOf hostSandboxOn)."nix-daemon-custom".serviceConfig.PrivateMounts or false == true;
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
    scenarioAbImage
    scenarioLiveDefault
    scenarioExtraEnvsAggregated
    scenarioAbStage
    scenarioForgejoPort
    scenarioAbBasenameAssert
    scenarioApplianceClone
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

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
#   - multi  → one `forgejo-runner-<name>` per instance, each relocated-store
#              wired, with its own token mount + uuid/labels;
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

  # Registration-uuid-shaped placeholder shared by scenarios. The module
  # forwards `uuid` verbatim into the connection map (it is an identifier,
  # not a credential) and never reads it.
  dummyUuid = "00000000-0000-0000-0000-000000000000";

  # Settings shared by every scenario (one `default` instance, cache key, NO
  # SSH keys — build-only / test, no push-back). `baseModule` adds the
  # required uuid; `noUuidModule` leaves it out for the failing-eval scenario.
  # enableSandbox is NOT set here — each scenario that asserts on sandbox
  # state sets it explicitly (tests must not rely on the nixtache default).
  # sshPrivateKey / sshPublicKey intentionally omitted (optional).
  commonRunner = {
    enable = true;
    forgejoUrl = "http://localhost:3000";
    cache = {
      enable = true;
      domain = "bincache.test";
      port = 5000;
    };
    secrets.cachePrivateKey = dummySecret;
  };

  # Minimal host + module config shared by every scenario. Only `store.path`
  # (and the `extra` module) varies. stateVersion follows nixpkgs' own test
  # convention (lib.trivial.release) so the test exercises the current
  # release, not a pinned old one.
  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    services.nixtache.runner = commonRunner // {
      instances.default = { uuid = dummyUuid; tokenFile = dummySecret; };
    };
  };
  noUuidModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    services.nixtache.runner = commonRunner // {
      instances.default.tokenFile = dummySecret;
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
  instancesOf = host: (containerCfg host).services.forgejo-runner.instances;
  loadCred = svc: svc."forgejo-runner-default".serviceConfig.LoadCredential or [ ];
  hasCredPrefix = prefix: creds: lib.any (c: lib.hasPrefix prefix c) creds;
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
      forgejoBindPaths = svcSrv."forgejo-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      forgejoRequires = lib.elem "nix-daemon-custom.service" (svcSrv."forgejo-runner-default".requires or [ ]);
      forgejoAfter = lib.elem "nix-daemon-custom.service" (svcSrv."forgejo-runner-default".after or [ ]);
      nixServeBindPaths = svcSrv."nix-serve".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      # clone on a nix-enabled container: storage seeds through the system daemon
      storageRequiresSystemDaemon = lib.elem "nix-daemon.service" (svcSrv."nix-daemon-storage".requires or [ ]);
      storageDaemonEnv = lib.elem "NIX_REMOTE=daemon" (svcSrv."nix-daemon-storage".serviceConfig.Environment or [ ]);
      socketPath = (socketsOf hostSrv)."nix-daemon-custom".listenStreams == [ "/srv/nix/var/nix/daemon-socket/socket" ];
      srvMountPoint = (bindMountsOf hostSrv)."srv-nix".mountPoint == "/srv";
      # per-instance token mount present, SSH mounts / SSH LoadCredentials
      # absent (the token's own upstream LoadCredential IS present even here
      # — asserted separately by scenarioRegistration)
      tokenMount = (bindMountsOf hostSrv)."runner-token-default".mountPoint == "/var/secrets/runner/default/token";
      noFlakeSshMount = !(has (bindMountsOf hostSrv) "flake-ssh-private-key");
      noUpdateSshMount = !(has (bindMountsOf hostSrv) "update-ssh-private-key");
      noSshLoadCredential =
        !(hasCredPrefix "flake_ssh_" (loadCred svcSrv)
          || hasCredPrefix "update_ssh_" (loadCred svcSrv));
      # enableSandbox=false (explicit in baseModule) → no CAP_SYS_ADMIN granted
      # (the container stays unprivileged; sandbox is off). The sandbox-ON path
      # is covered by scenarioSandboxOn.
      noSandboxCap = !(lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities);
      # CAP_IPC_LOCK is granted even with sandbox off: builds run either way,
      # and secmem-locking test suites (libgcrypt t-secmem/t-sexp, gnupg)
      # fail on mlock(2) EPERM without it (nspawn drops it by default).
      hasIpcLock = lib.elem "CAP_IPC_LOCK" hostSrv.config.containers."runner".additionalCapabilities;
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
      noForgejoBindPaths = (svcRoot."forgejo-runner-default".serviceConfig.BindPaths or [ ]) == [ ];
      noForgejoDep = !(lib.elem "nix-daemon-custom.service" (svcRoot."forgejo-runner-default".after or [ ]));
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

  # --- scenario: registration wiring (uuid + token pair model) -------------
  # The default instance lands in the in-container `services.forgejo-runner`
  # map with connection `default` (shared url + per-instance uuid), the bare
  # token read from the read-only bind mount via the upstream secrets
  # templating (token_url → LoadCredential on the runner service), and the
  # container nix daemon trusting the instance's dynamic service user
  # (`forgejo-runner-<name>` — NSS-visible name of the DynamicUser unit; the
  # removed static `gitea-runner` account must not appear).
  instSrv = (instancesOf hostSrv)."default";
  connSrv = instSrv.settings.server.connections.default;
  scenarioRegistration = {
    name = "registration: connection url+uuid, bare-token bind mount → token_url/LoadCredential, trusted service user";
    checks = {
      connUrl = connSrv.url == "http://localhost:3000";
      connUuid = connSrv.uuid == dummyUuid;
      tokenUrl = instSrv.secrets.server.connections.default.token_url == "/var/secrets/runner/default/token";
      tokenMountHostPath = (bindMountsOf hostSrv)."runner-token-default".hostPath == toString dummySecret;
      tokenMountRO = (bindMountsOf hostSrv)."runner-token-default".isReadOnly == true;
      tokenCred = lib.elem "server__connections__default__token_url:/var/secrets/runner/default/token" (loadCred svcSrv);
      labelsLocation = instSrv.settings.runner.labels == [ "nixos:host" ];
      trustedUser = lib.elem "forgejo-runner-default" (containerCfg hostSrv).nix.settings.trusted-users;
      noGiteaTrusted = !(lib.elem "gitea-runner" (containerCfg hostSrv).nix.settings.trusted-users);
    };
  };

  # --- failing-eval scenarios: the removed/added instance options ----------
  # `name` no longer exists (runners don't self-report their name — it is
  # fixed when the registration is created in Forgejo); `uuid` is required
  # (each instance is its own registration). Both must fail evaluation; the
  # module system turns the errors into throws that tryEval catches.
  tryNamed = builtins.tryEval (mkHost "/srv" {
    services.nixtache.runner.instances.default.name = "whatever";
  }).config.system.build.toplevel.outPath;
  hostNoUuid = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.runner
      noUuidModule
      { services.nixtache.runner.store.path = "/srv"; }
    ];
  };
  tryNoUuid = builtins.tryEval hostNoUuid.config.system.build.toplevel.outPath;
  scenarioInstanceOptionSurface = {
    name = "instance option surface: setting `name` fails eval; absent `uuid` fails eval";
    checks = {
      nameRefused = !tryNamed.success;
      uuidRequired = !tryNoUuid.success;
    };
  };

  # --- scenario D: multiple instances share the relocated store -----------
  hostMulti = mkHost "/srv" {
    services.nixtache.runner.instances = {
      default.tokenFile = dummySecret;
      test = {
        uuid = "11111111-1111-1111-1111-111111111111";
        labels = [ "test:host" ];
        tokenFile = dummySecret;
      };
    };
  };
  svcMulti = servicesOf hostMulti;
  instMulti = instancesOf hostMulti;
  scenarioMulti = {
    name = "instances.<name>: one forgejo-runner-<name> per instance, each wired, distinct uuid/token/labels";
    checks = {
      hasForgejoDefault = has svcMulti "forgejo-runner-default";
      hasForgejoTest = has svcMulti "forgejo-runner-test";
      defaultBindPaths = svcMulti."forgejo-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      testBindPaths = svcMulti."forgejo-runner-test".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
      defaultLabels = instMulti."default".settings.runner.labels == [ "nixos:host" ];
      testLabels = instMulti."test".settings.runner.labels == [ "test:host" ];
      # each instance is its own registration: own uuid in its own connection
      defaultUuid = instMulti."default".settings.server.connections.default.uuid == dummyUuid;
      testUuid = instMulti."test".settings.server.connections.default.uuid == "11111111-1111-1111-1111-111111111111";
      testUrl = instMulti."test".settings.server.connections.default.url == "http://localhost:3000";
      # ...and its own read-only token bind mount
      defaultTokenMount = (bindMountsOf hostMulti)."runner-token-default".mountPoint == "/var/secrets/runner/default/token";
      testTokenMount = (bindMountsOf hostMulti)."runner-token-test".mountPoint == "/var/secrets/runner/test/token";
      testTokenUrl = instMulti."test".secrets.server.connections.default.token_url == "/var/secrets/runner/test/token";
      # the container nix daemon trusts each instance's dynamic service user
      trustedDefault = lib.elem "forgejo-runner-default" (containerCfg hostMulti).nix.settings.trusted-users;
      trustedTest = lib.elem "forgejo-runner-test" (containerCfg hostMulti).nix.settings.trusted-users;
      noGiteaTrusted = !(lib.elem "gitea-runner" (containerCfg hostMulti).nix.settings.trusted-users);
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
      # subset check: the service also carries the upstream token
      # LoadCredential (asserted by scenarioRegistration)
      loadCredential = lib.all (c: lib.elem c (loadCred svcSsh)) [
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
      # ...and the relocated-store daemon (store.path="/srv" → nix-daemon-custom
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
  # supplied) a LoadCredential on every forgejo-runner service.
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
      hasSigningCred = hasCredPrefix "sysupdate_signing_key:" (loadCred (servicesOf hostAb));
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

  # --- scenario J: appliance HOST (nix.enable=false) → container appliance mode
  # The module keys the container's appliance mode on the HOST: the container's
  # nix module is disabled (no system daemon can exist inside it — the
  # daemon-socket dir is a read-only host bind), gc/optimise go with it
  # (nixpkgs asserts they need nix), the module renders nix.conf itself with
  # the same settings content (CI keeps system-features/substituters/
  # trusted-users), and the nix CLI ships explicitly. Clone seeds standalone
  # from a scratch copy of the host's (now real) store DB (sec. 11.3).
  hostApplianceClone = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
    nix.enable = false;
  };
  cfgAppliance = containerCfg hostApplianceClone;
  svcAppliance = servicesOf hostApplianceClone;

  # --- scenario: appliance HOST (nix.enable=false) — nspawn bind sources ----
  # nixpkgs' container start unconditionally bind-ros the host's
  # /nix/var/nix/db + daemon-socket into the container; on a nix-less
  # appliance those paths don't exist and the container fails to start.
  # The module guarantees them as empty dirs via tmpfiles.
  hostApplianceHost = mkHost "/srv" {
    services.nixtache.runner.enableSandbox = false;
    nix.enable = false;
  };
  scenarioApplianceHost = {
    name = "appliance host (nix.enable=false): nspawn bind sources guaranteed via tmpfiles";
    checks = {
      hostDbDir = lib.elem "d /nix/var/nix/db 0755 root root -"
        hostApplianceHost.config.systemd.tmpfiles.rules;
      hostSocketDir = lib.elem "d /nix/var/nix/daemon-socket 0755 root root -"
        hostApplianceHost.config.systemd.tmpfiles.rules;
    };
  };
  scenarioApplianceClone = {
    name = "appliance host → container appliance mode: nix module disabled, nix.conf rendered, CLI shipped, clone standalone (sec. 11.3)";
    checks = {
      containerNixDisabled = cfgAppliance.nix.enable == false;
      gcOff = cfgAppliance.nix.gc.automatic == false;
      optimiseOff = cfgAppliance.nix.optimise.automatic == false;
      nixConfRendered = cfgAppliance.environment.etc ? "nix/nix.conf";
      # The fleet's closure is content-addressed — the rendered nix.conf must
      # carry the feature (the daemon ignores client-side overrides, so the
      # in-container system conf is the only effective source).
      nixConfHasCa = lib.hasInfix "ca-derivations"
        (cfgAppliance.environment.etc."nix/nix.conf".source.text or "");
      nixCliShipped = builtins.elem cfgAppliance.nix.package cfgAppliance.environment.systemPackages;
      # The CI-critical feature list still reaches the container's settings
      # (the host's nix module is off, so the module propagates the evaluated
      # value via specialArgs).
      systemFeaturesKept = builtins.elem "kvm" (cfgAppliance.nix.settings.system-features or [ ]);
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

  # --- scenario: overlay mode lower-store provider — host-dependent ----------
  # nix-enabled host: the container's system nix-daemon provides the lower
  # (lower-store=daemon). Appliance host: no system daemon can exist, so the
  # overlay reads the RO-bound host DB directly (lower-store=local) — the
  # daemon URL would self-reference and fork-loop otherwise.
  hostOverlay = mkHost "/srv" {
    services.nixtache.runner = {
      enableSandbox = false;
      store.mode = "overlay";
    };
  };
  hostApplianceOverlay = mkHost "/srv" {
    services.nixtache.runner = {
      enableSandbox = false;
      store.mode = "overlay";
    };
    nix.enable = false;
  };
  execOverlayOf = host: (servicesOf host)."nix-daemon-custom".serviceConfig.ExecStart or "";
  scenarioOverlayLower = {
    name = "overlay mode: lower-store=daemon on nix-enabled hosts, lower-store=local on appliance hosts";
    checks = {
      hostLowerDaemon = lib.hasInfix "lower-store=daemon" (execOverlayOf hostOverlay);
      hostNoLocal = !(lib.hasInfix "lower-store=local" (execOverlayOf hostOverlay));
      applianceLowerLocal = lib.hasInfix "lower-store=local" (execOverlayOf hostApplianceOverlay);
      applianceNoDaemon = !(lib.hasInfix "lower-store=daemon" (execOverlayOf hostApplianceOverlay));
      # Appliance overlay: no storage oneshot (the overlay mount replaces it).
      applianceNoStorage = !(has (servicesOf hostApplianceOverlay) "nix-daemon-storage");
      applianceOverlayMount = has (servicesOf hostApplianceOverlay) "nix-daemon-overlay-mount";
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

  # --- scenario: nginx edge cache on the cache vhost (default: on) --------
  # The zone + the "/nar/" (immutable, 30d) and "/" (narinfo: 6h positive,
  # 1m negative) cache policies land on the cache vhost; the ab staging
  # location (scenarioAbStage) keeps its static root untouched.
  vhostSrv = hostSrv.config.services.nginx.virtualHosts."bincache.test";
  scenarioNginxCache = {
    name = "cache.nginxCache default on: zone + /nar/ + narinfo policies on the vhost";
    checks = {
      zoneEnabled = hostSrv.config.services.nginx.proxyCachePath."nixtache-bincache".enable;
      zoneMaxSize = hostSrv.config.services.nginx.proxyCachePath."nixtache-bincache".maxSize == "10g";
      narLocation = vhostSrv.locations ? "/nar/";
      narCached = lib.hasInfix "proxy_cache nixtache-bincache" vhostSrv.locations."/nar/".extraConfig;
      narCoalesced = lib.hasInfix "proxy_cache_lock on" vhostSrv.locations."/nar/".extraConfig;
      narStale = lib.hasInfix "proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504"
        vhostSrv.locations."/nar/".extraConfig;
      narLongTtl = lib.hasInfix "proxy_cache_valid 200 30d" vhostSrv.locations."/nar/".extraConfig;
      narinfoNegativeTtl = lib.hasInfix "proxy_cache_valid 404 1m" (vhostSrv.locations."/".extraConfig or "");
      # staging store (enabled in hostAb) must not inherit cache directives:
      # asserted there via nginxAutoindex; here we pin the default host's
      # vhost to exactly the two cache locations.
      onlyCacheLocations = builtins.attrNames vhostSrv.locations == [ "/" "/nar/" ];
    };
  };

  hostCacheOff = mkHost "/srv" {
    services.nixtache.runner.cache.nginxCache.enable = false;
  };
  vhostCacheOff = hostCacheOff.config.services.nginx.virtualHosts."bincache.test";
  scenarioNginxCacheOff = {
    name = "cache.nginxCache.enable=false: plain proxy-pass, no zone, no /nar/ location";
    checks = {
      noZone = hostCacheOff.config.services.nginx.proxyCachePath == { };
      noNarLocation = !(vhostCacheOff.locations ? "/nar/");
      noCacheDirectives = !(lib.hasInfix "proxy_cache" (vhostCacheOff.locations."/".extraConfig or ""));
    };
  };

  # --- scenario: daemon lifecycle + nix-serve scheduling --------------------
  # KillMode=mixed: per-connection daemon workers must not outlive the unit
  # (KillMode=process leaked them — chronic "remains running" records).
  # nix-serve gets a mild CPU/IO edge over the (default-scheduled) CI units.
  scenarioCacheBackendLifecycle = {
    name = "nix-daemon-custom KillMode=mixed (no leaked workers); nix-serve scheduling edge";
    checks = {
      daemonKillMode = svcSrv."nix-daemon-custom".serviceConfig.KillMode == "mixed";
      nixServeNice = svcSrv."nix-serve".serviceConfig.Nice == -5;
      nixServeIoClass = svcSrv."nix-serve".serviceConfig.IOSchedulingClass == "best-effort";
      nixServeIoPrio = svcSrv."nix-serve".serviceConfig.IOSchedulingPriority == 0;
      runnersNotOutranking = !(svcSrv."forgejo-runner-default".serviceConfig ? Nice);
    };
  };

  scenarios = [
    scenarioSrv
    scenarioRoot
    scenarioEmpty
    scenarioRegistration
    scenarioInstanceOptionSurface
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
    scenarioApplianceHost
    scenarioOverlayLower
    scenarioGitSshHost
    scenarioResources
    scenarioNginxCache
    scenarioNginxCacheOff
    scenarioCacheBackendLifecycle
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

    # -- module→action CONTRACT RUN -----------------------------------------
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
    # ...and complete the live path (switch mode): activated marker in its log
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

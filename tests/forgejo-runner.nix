# Pure-evaluation tests for the forgejo-runner module.
#
# These verify the `store.path` contract WITHOUT running any container or VM:
#
#   - "/"    → reuse the container's system nix-daemon: no custom services,
#              no BindPaths, no `srv` bind mount;
#   - "/srv" → relocate the store to <path>/nix: run the custom nix-daemon +
#              storage oneshot, inject a BindPaths bind onto /nix into the
#              working services (gitea-runner, nix-serve), and wire
#              `after/requires = nix-daemon-custom.service`;
#   - ""     → the mandatory-path assertion must fire.
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

  # Dummy secret value shared by every scenario. The module only forwards
  # secret paths as bind-mount hostPaths / LoadCredential, never reading them
  # at eval time, so /dev/null is fine.
  dummySecret = /dev/null;

  # Minimal host + module config shared by every scenario. Only `store.path`
  # varies between scenarios.
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
      secrets = {
        tokenFile = dummySecret;
        sshPrivateKey = dummySecret;
        sshPublicKey = dummySecret;
        cachePrivateKey = dummySecret;
      };
    };
  };

  mkHost = storePath:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.forgejo-runner
        baseModule
        { services.nixtache.forgejo-runner.store.path = storePath; }
      ];
    };

  containerCfg = host: host.config.containers."forgejo-runner".config;
  servicesOf = host: (containerCfg host).systemd.services;
  socketsOf = host: (containerCfg host).systemd.sockets;
  bindMountsOf = host: host.config.containers."forgejo-runner".bindMounts;
  has = set: name: set ? ${name};

  # --- scenario A: relocated store ----------------------------------------
  hostSrv = mkHost "/srv";
  svcSrv = servicesOf hostSrv;
  scenarioSrv = {
    name = "store.path=\"/srv\" runs the custom daemon and injects BindPaths";
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
    };
  };

  # --- scenario B: native store -------------------------------------------
  hostRoot = mkHost "/";
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
  # Forcing toplevel.outPath is what drives the assertion check.
  tryEmpty = builtins.tryEval (mkHost "").config.system.build.toplevel.outPath;
  scenarioEmpty = {
    name = "store.path=\"\" fires the mandatory-path assertion";
    checks = { refused = !tryEmpty.success; };
  };

  scenarios = [ scenarioSrv scenarioRoot scenarioEmpty ];

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

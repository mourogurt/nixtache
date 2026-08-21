# Pure-eval tests against ALREADY-IMPLEMENTED nixtache modules (spec 06 + 08 §5/§7).
#
# These PASS NOW (green) — the regression baseline + coverage-gap fillers:
#   - ab-image: storeFs/storeCompression/storeCompressionLevel forwarding to
#     repart; storeCompression=null drops the keys; ukiTries → boot.uki.tries.
#   - runner.deploy.ab: retain reaches the gc script (V1); cache/runnerHost
#     asserts (V2/V3); hostBackup wired as srv-nix bindMount hostPath (gap).
#   - deploy-target.ab: forceAfterTimeout=true force-branch in gating script (V4).
#   - runner.store: path="/" + ab-image.enable → assertion (R3, already in store.nix).
#
# Fast, no KVM. Exposed via checks.<system>.ab-existing.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  dummySecret = /dev/null;

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
  };

  # =========================================================================
  # ab-image wiring (compression, ukiTries)
  # =========================================================================
  mkImage = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ self.nixosModules.ab-image baseModule extra ];
    };
  parts = h: h.config.image.repart.partitions;

  hostErofsZstd = mkImage {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      imageVersion = "1";
      storeFs = "erofs";
      storeCompression = "zstd";
      storeCompressionLevel = 19;
    };
  };
  pe = parts hostErofsZstd;
  scenarioCompression = {
    name = "ab-image: storeFs/storeCompression/storeCompressionLevel forwarded to repart";
    checks = {
      formatErofs = pe.nix-store.repartConfig.Format or null == "erofs";
      compressionZstd = pe.nix-store.repartConfig.Compression or null == "zstd";
      level19 = pe.nix-store.repartConfig.CompressionLevel or null == 19;
    };
  };

  hostNoCompression = mkImage {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      storeCompression = null;
    };
  };
  pn = parts hostNoCompression;
  scenarioNoCompression = {
    name = "ab-image: storeCompression=null → no Compression keys in repart";
    checks = {
      noCompressionKey = !(pn.nix-store.repartConfig ? Compression);
      noLevelKey = !(pn.nix-store.repartConfig ? CompressionLevel);
    };
  };

  hostUkiTries = mkImage {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      ukiTries = 5;
    };
  };
  scenarioUkiTries = {
    name = "ab-image: ukiTries propagates to boot.uki.tries";
    checks = { ukiTries5 = hostUkiTries.config.boot.uki.tries == 5; };
  };

  # =========================================================================
  # runner.deploy.ab (V1 retain-script, V2/V3 asserts) + runner.store hostBackup
  # =========================================================================
  runnerBase = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    services.nixtache.runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache = { enable = true; domain = "bincache.test"; port = 5000; };
      instances.default.tokenFile = dummySecret;
      secrets.cachePrivateKey = dummySecret;
      store.path = "/srv";
    };
  };
  mkRunner = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ self.nixosModules.runner runnerBase extra ];
    };

  # V1: retain value reaches the gc script (real text inspection)
  hostRetain = mkRunner {
    services.nixtache.runner.deploy.ab = {
      enable = true;
      runnerHost = "bincache.test";
      retain = 3;
      signingKeyFile = dummySecret;
    };
  };
  gcScript = hostRetain.config.systemd.services."nixtache-ab-gc".script;
  scenarioRetain = {
    name = "runner.deploy.ab: retain value reaches nixtache-ab-gc script (V1)";
    checks = {
      retainInScript = lib.hasInfix "retain=3" gcScript;
      sortsDesc = lib.hasInfix "sort -rn" gcScript;
      regenSums = lib.hasInfix "sha256sum" gcScript && lib.hasInfix "SHA256SUMS" gcScript;
      removesRawAndEfi = lib.hasInfix ".nix-store.raw" gcScript && lib.hasInfix ".efi" gcScript;
      # §11.1 fix: with signingKeyFile set, GC re-signs SHA256SUMS.gpg (host-path
      # sops key, readable on the host) so Verify=yes targets don't reject a stale .gpg.
      reSignsWhenKey = lib.hasInfix "gpg --batch --yes --detach-sign" gcScript;
      gnupgInPath =
        builtins.any (p: lib.hasInfix "gnupg" (p.name or ""))
          hostRetain.config.systemd.services."nixtache-ab-gc".path;
    };
  };

  # V1 (no key): signingKeyFile=null → GC must NOT embed the re-sign branch and
  # must drop the .gpg (no signature → no stale signature).
  hostRetainNoKey = mkRunner {
    services.nixtache.runner.deploy.ab = {
      enable = true;
      runnerHost = "bincache.test";
      retain = 3;
      # signingKeyFile unset → null
    };
  };
  gcScriptNoKey = hostRetainNoKey.config.systemd.services."nixtache-ab-gc".script;
  scenarioRetainNoKey = {
    name = "runner.deploy.ab: signingKeyFile=null → GC drops .gpg, no re-sign branch";
    checks = {
      noDetachSign = !(lib.hasInfix "detach-sign" gcScriptNoKey);
      dropsGpg = lib.hasInfix "SHA256SUMS.gpg" gcScriptNoKey;
      noGnupgInPath =
        !(builtins.any (p: lib.hasInfix "gnupg" (p.name or ""))
          hostRetainNoKey.config.systemd.services."nixtache-ab-gc".path);
    };
  };

  # V2: ab.enable=true + cache.enable=false → assertion fires
  tryCacheAssert = builtins.tryEval
    (mkRunner {
      services.nixtache.runner.cache.enable = false;
      services.nixtache.runner.deploy.ab = {
        enable = true;
        runnerHost = "bincache.test";
      };
    }).config.system.build.toplevel.outPath;
  scenarioCacheAssert = {
    name = "runner.deploy.ab: enable=true + cache.enable=false → eval refuses (V2)";
    checks = { refused = !tryCacheAssert.success; };
  };

  # V3: runnerHost="" → assertion fires (cache on, basename default-matches)
  tryRunnerHostAssert = builtins.tryEval
    (mkRunner {
      services.nixtache.runner.deploy.ab = {
        enable = true;
        runnerHost = "";
      };
    }).config.system.build.toplevel.outPath;
  scenarioRunnerHostAssert = {
    name = "runner.deploy.ab: runnerHost=\"\" → eval refuses (V3)";
    checks = { refused = !tryRunnerHostAssert.success; };
  };

  # hostBackup wired as srv-nix bindMount hostPath (coverage gap)
  hostSrv = mkRunner { };
  scenarioHostBackup = {
    name = "runner.store: hostBackup wired as srv-nix bindMount hostPath (gap)";
    checks = {
      hostPathBackup =
        hostSrv.config.containers."runner".bindMounts."srv-nix".hostPath
        == hostSrv.config.services.nixtache.runner.store.hostBackup;
    };
  };

  # =========================================================================
  # deploy-target.ab: forceAfterTimeout=true branch in gating script (V4)
  # =========================================================================
  mkTarget = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.deploy-target
        self.nixosModules.runner
        runnerBase
        extra
      ];
    };
  hostForce = mkTarget {
    services.nixtache.deploy-target.ab = {
      enable = true;
      gating = true;
      forgejoApiTokenFile = dummySecret;
      forceAfterTimeout = true;
      idleWaitTimeout = 600;
    };
    systemd.sysupdate.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;
  };
  forceScript = hostForce.config.systemd.services."nixtache-ab-apply".script;
  scenarioForceAfterTimeout = {
    name = "deploy-target.ab: forceAfterTimeout=true → force branch in gating script (V4)";
    checks = {
      forceFlagOne = lib.hasInfix "\"1\"" forceScript;
      forceBranchText = lib.hasInfix "forceAfterTimeout=true" forceScript;
    };
  };

  # =========================================================================
  # R3: store.path="/" + ab-image.enable → assertion (already in store.nix)
  # =========================================================================
  tryNativeAbAssert = builtins.tryEval
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.runner
        self.nixosModules.ab-image
        baseModule
        {
          services.nixtache.runner = {
            enable = true;
            forgejoUrl = "http://localhost:3000";
            cache = { enable = true; domain = "bincache.test"; port = 5000; };
            instances.default.tokenFile = dummySecret;
            secrets.cachePrivateKey = dummySecret;
            store.path = "/";
          };
          services.nixtache.ab-image = {
            enable = true;
            imageId = "h";
          };
        }
      ];
    }).config.system.build.toplevel.outPath;
  scenarioR3Assert = {
    name = "runner.store: path=\"/\" + ab-image.enable → eval refuses (R3, A/B native-store assert)";
    checks = { refused = !tryNativeAbAssert.success; };
  };

  # =========================================================================
  # Report aggregation (same pattern as tests/ab-image.nix)
  # =========================================================================
  scenarios = [
    scenarioCompression
    scenarioNoCompression
    scenarioUkiTries
    scenarioRetain
    scenarioRetainNoKey
    scenarioCacheAssert
    scenarioRunnerHostAssert
    scenarioHostBackup
    scenarioForceAfterTimeout
    scenarioR3Assert
  ];

  failed = builtins.concatMap
    (s: if builtins.all (c: c) (builtins.attrValues s.checks) then [ ] else [ s.name ])
    scenarios;
  allOk = failed == [ ];
  report = lib.concatStringsSep "\n" (lib.flatten (map
    (s: [ s.name ] ++ (map
      (cn: "  ${if s.checks.${cn} then "ok  " else "FAIL"}  ${cn}")
      (builtins.attrNames s.checks)))
    scenarios));
  failMsg = lib.optionalString (!allOk) "FAILED: ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "ab-existing-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

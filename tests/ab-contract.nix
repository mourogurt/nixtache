# Pure-eval CONTRACT tests for the ab-provision / overlay-nix / runner
# store.mode wiring.
#
# These pin the wiring + assertion contracts for:
#   - modules/deploy-target/ab-provision.nix  → services.nixtache.deploy-target.ab.partitions.*
#   - modules/overlay-nix/default.nix         → services.nixtache.overlay-nix.*  (+ flake.nix nixosModules.overlay-nix)
#   - store.mode option in modules/runner/store.nix
#
# Graceful degradation:
#   - wiring scenarios (contract*) flag a named `moduleImplemented=false` check
#     when the module eval refuses — instead of crashing the whole suite;
#   - assert scenarios (assertContract*) are GATED by a `modulePresent` probe so
#     they cannot falsely pass while a module is missing (an absent option
#     refuses just like a firing assertion would).
#
# Fast, no KVM. Exposed via checks.<system>.ab-contract.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  # String, not a path literal: `bindMounts.<name>.hostPath` (container option)
  # is `nullOr str` and is set from `secrets.cachePrivateKey` in cache.nix. A
  # path literal (`/dev/null`) fails that type check when `probeOK` forces deep
  # evaluation (toplevel.outPath). `types.path` options (tokenFile, cachePrivateKey)
  # accept strings too (NixOS coerces), so a single string dummy satisfies both.
  dummySecret = "/dev/null";
  # Dummy pubring as a STORE path (a /dev/null path literal is forbidden in
  # pure eval — interpolating it into the tmpfiles rule forces a store copy).
  dummyPubkey = pkgs.writeText "dummy-pubring.pgp" "not-a-real-key";

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
  };

  # Force toplevel.outPath to surface option-missing / assertion errors.
  probeOK = modules:
    (builtins.tryEval
      ((nixpkgs.lib.nixosSystem { inherit system modules; }).config.system.build.toplevel.outPath)
    ).success;
  evalCfg = modules: (nixpkgs.lib.nixosSystem { inherit system modules; }).config;

  # wiring contract: green checks if eval OK, else moduleImplemented=false (red, named)
  contract = name: modules: checksFn:
    let ok = probeOK modules; in
    {
      inherit name;
      checks = if ok then checksFn (evalCfg modules) else { moduleImplemented = false; };
    };

  # assert contract: green only when module is present AND the bad config refuses
  assertContract = name: modulePresent: badModules: {
    inherit name;
    checks = {
      inherit modulePresent;
      badConfigRefused = !(probeOK badModules);
    };
  };

  runnerBase = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    # Dummy root FS + grub off — same rationale as abPartCfg (test-only concern,
    # no module should dictate the root filesystem or boot loader). Lets
    # `probeOK` force toplevel.outPath without firing base NixOS assertions.
    fileSystems."/".fsType = lib.mkDefault "tmpfs";
    boot.loader.grub.enable = lib.mkDefault false;
    services.nixtache.runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache = { enable = true; domain = "bincache.test"; port = 5000; };
      instances.default.tokenFile = dummySecret;
      secrets.cachePrivateKey = dummySecret;
      store.path = "/srv";
    };
  };

  # overlay-nix module attr is absent until implemented → fall back to an empty
  # module so an OPTION-missing error (caught by `contract`) is what surfaces,
  # rather than an attrset-missing crash.
  overlayMod = self.nixosModules.overlay-nix or ({ ... }: { });

  # ========================================================================
  # ab.partitions contract (modules/deploy-target/ab-provision.nix)
  # ========================================================================
  abPartCfg = ab-extra: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
    # Dummy root FS so the base NixOS root-filesystem assertion does not fire
    # during `probeOK` (which forces `toplevel.outPath`). The module under test
    # never reads this — it's purely to satisfy the base system's bootability
    # check. Same pattern nixpkgs' own test VMs use. `boot.loader.grub` is
    # already turned off by `deploy-target/ab.nix` (mkDefault) when ab.enable.
    # (tmpfs: nixpkgs' filesystems.nix auto-sets device="tmpfs" to match.)
    fileSystems."/".fsType = lib.mkDefault "tmpfs";
    systemd.sysupdate.enable = true;                      # ab.enable assert requires it
    boot.loader.systemd-boot.bootCounting.enable = true;  # ab.enable assert requires it
    services.nixtache.deploy-target = {
      enable = true;
      ab = {
        enable = true;
        gating = false;
        partitions = ({
          enable = true;
          slotSize = "512M";
          slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
          slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
        } // ab-extra);
      };
    };
  };

  abPartPresent = probeOK [ self.nixosModules.deploy-target (abPartCfg { }) ];

  scenarioPartWiring = contract
    "ab.partitions: enable=true → nixtache-ab-provision oneshot before sysupdate (P1)"
    [ self.nixosModules.deploy-target (abPartCfg { }) ]
    (cfg: {
      hasService = cfg.systemd.services ? "nixtache-ab-provision";
      isOneshot = cfg.systemd.services."nixtache-ab-provision".serviceConfig.Type or null == "oneshot";
      beforeSysupdate = lib.elem "systemd-sysupdate.service"
        (cfg.systemd.services."nixtache-ab-provision".before or [ ]);
      # The module owns ALL of systemd.sysupdate: enables it and derives the
      # UKI transfer (default bootTarget="auto" → ESP /EFI/Linux via $BOOT).
      sysupdateEnabled = cfg.systemd.sysupdate.enable == true;
      bootImageAuto =
        (cfg.systemd.sysupdate.transfers."20-boot-image".Target.PathRelativeTo or null) == "boot"
        && (cfg.systemd.sysupdate.transfers."20-boot-image".Target.Path or null) == "/EFI/Linux";
    });

  scenarioPartBootTargetDir = contract
    "ab.partitions: bootTarget=/dir → UKI transfer Target Path=dir (hosts without ESP)"
    [ self.nixosModules.deploy-target (abPartCfg { bootTarget = "/var/lib/nixtache/ab-slots/"; }) ]
    (cfg:
      let t = cfg.systemd.sysupdate.transfers."20-boot-image".Target; in
      {
        pathIsDir = t.Path or null == "/var/lib/nixtache/ab-slots/";
        noPathRelativeTo = !(t ? PathRelativeTo);
        efiMatchPattern = t.MatchPattern or null == [ "nixtache_@v.efi" ];
      });

  scenarioPartDiffDisks = contract
    "ab.partitions: slot_a.storage≠slot_b.storage → 2 transfers InstancesMax=1 (P4)"
    [ self.nixosModules.deploy-target (abPartCfg {
        slot_b = { type = "partition"; storage = "/dev/vdc"; label = "_empty"; };
      }) ]
    (cfg:
      let t = cfg.systemd.sysupdate.transfers; in
      {
        hasTwoTransfers = t ? "10-nix-store-a" && t ? "10-nix-store-b";
        instancesMaxOneEach =
          (t."10-nix-store-a".Target.InstancesMax or null) == 1
          && (t."10-nix-store-b".Target.InstancesMax or null) == 1;
      });

  scenarioPartSameDisk = contract
    "ab.partitions: same storage → 1 transfer InstancesMax=2 (P4)"
    [ self.nixosModules.deploy-target (abPartCfg { }) ]
    (cfg:
      let t = cfg.systemd.sysupdate.transfers; in
      {
        hasOneTransfer = t ? "10-nix-store";
        instancesMaxTwo = (t."10-nix-store".Target.InstancesMax or null) == 2;
      });

  scenarioPartRegularFile = contract
    "ab.partitions: type=regular-file → no provision service, Target.Type=regular-file (P5)"
    [ self.nixosModules.deploy-target (abPartCfg {
        slot_a = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; };
        slot_b = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; };
      }) ]
    (cfg: {
      noProvisionService = !(cfg.systemd.services ? "nixtache-ab-provision");
      targetIsRegularFile =
        cfg.systemd.sysupdate.transfers."10-nix-store".Target.Type or null == "regular-file";
    });

  scenarioPartAssertTypeMismatch = assertContract
    "ab.partitions assert: slot_a.type≠slot_b.type → eval refuses (A1)"
    abPartPresent
    [ self.nixosModules.deploy-target (abPartCfg {
        slot_b = { type = "regular-file"; storage = "/x"; };
      }) ];

  scenarioPartAssertSizeMismatch = assertContract
    "ab.partitions assert: storeSize≠slotSize (absolute) → eval refuses (A2)"
    abPartPresent
    [
      self.nixosModules.deploy-target
      self.nixosModules.ab-image
      (abPartCfg { slotSize = lib.mkForce "1G"; })
      { services.nixtache.ab-image = { enable = true; imageId = "h"; storeSize = "2G"; }; }
    ];

  scenarioPartAssertAutoInitRegularFile = assertContract
    "ab.partitions assert: autoInit=true + type=regular-file → eval refuses (A3)"
    abPartPresent
    [ self.nixosModules.deploy-target (abPartCfg {
        slotSize = lib.mkForce "512M";
        autoInit = true;
        slot_a = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; };
        slot_b = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; };
      }) ];

  scenarioPartAssertBadStorage = assertContract
    "ab.partitions assert: partition + storage not /dev/…/auto → eval refuses (A4)"
    abPartPresent
    [ self.nixosModules.deploy-target (abPartCfg {
        slot_a = { type = "partition"; storage = "/srv/foo"; label = "nix-store_1"; };
      }) ];

  scenarioPartSourceUrl = contract
    "ab.partitions: source=http URL → Source url-file + trailing slash + imageId MatchPattern"
    [ self.nixosModules.deploy-target (abPartCfg {
        imageId = "myhost";
        source = "http://runner.example.com/ab-stage/myhost";
      }) ]
    (cfg:
      let s = cfg.systemd.sysupdate.transfers."10-nix-store".Source; in
      {
        isUrlFile = s.Type or null == "url-file";
        pathIsUrl = s.Path or null == "http://runner.example.com/ab-stage/myhost/";
        matchPattern = s.MatchPattern or null == [ "myhost_@v.nix-store.raw" ];
        bootImageFollowsSource =
          cfg.systemd.sysupdate.transfers."20-boot-image".Source.Path or null
          == "http://runner.example.com/ab-stage/myhost/";
      });

  scenarioPartSourceLocal = contract
    "ab.partitions: source=/local/dir → Source regular-file + plain local path (self-deploy; sysupdate rejects file:// for regular-file)"
    [ self.nixosModules.deploy-target (abPartCfg {
        source = "/var/lib/nixtache/ab-stage/myhost";
      }) ]
    (cfg:
      let s = cfg.systemd.sysupdate.transfers."10-nix-store".Source; in
      {
        isRegularFile = s.Type or null == "regular-file";
        pathIsLocalDir = s.Path or null == "/var/lib/nixtache/ab-stage/myhost/";
        matchPatternFallbackId = s.MatchPattern or null == [ "nixtache_@v.nix-store.raw" ];
      });

  scenarioPartAssertVerifyNoKey = assertContract
    "ab.partitions assert: verify=true без публичного ключа → eval refuses (A5)"
    abPartPresent
    [ self.nixosModules.deploy-target (abPartCfg { verify = true; }) ];

  scenarioPartAssertBothKeys = assertContract
    "ab.partitions assert: publicKeyFile+publicKey вместе → eval refuses (A6)"
    abPartPresent
    [ self.nixosModules.deploy-target (abPartCfg {
        publicKeyFile = dummyPubkey;
        publicKey = "-----BEGIN PGP PUBLIC KEY BLOCK-----";
      }) ];

  scenarioPartVerifyKey = contract
    "ab.partitions: publicKeyFile → Verify=yes + pubring в /etc (deployer=priv, target=pub)"
    [ self.nixosModules.deploy-target (abPartCfg { publicKeyFile = dummyPubkey; }) ]
    (cfg: {
      verifyYes = cfg.systemd.sysupdate.transfers."10-nix-store".Transfer.Verify or null == "yes";
      pubringInstalled = cfg.environment.etc ? "systemd/import-pubring.pgp";
    });

  # ========================================================================
  # overlay-nix contract (modules/overlay-nix/default.nix)
  # ========================================================================
  overlayCfg = {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
    # Dummy root FS + grub off — same test-only rationale as abPartCfg / runnerBase.
    fileSystems."/".fsType = lib.mkDefault "tmpfs";
    boot.loader.grub.enable = lib.mkDefault false;
    services.nixtache.overlay-nix = {
      enable = true;
      upperDir = "/var/lib/nix-overlay/upper";
      workDir = "/var/lib/nix-overlay/work";
    };
  };
  overlayPresent = probeOK [ overlayMod overlayCfg ];

  scenarioOverlayWiring = contract
    "overlay-nix: enable=true → overlay daemon/mount service + tmpfiles for upper/work (O1)"
    [ overlayMod overlayCfg ]
    (cfg: {
      hasOverlayService =
        (cfg.systemd.services ? "nix-daemon-overlay")
        || (cfg.systemd.services ? "nix-daemon-overlay-mount");
      hasOverlayTmpfiles =
        builtins.any (r: lib.hasInfix "/var/lib/nix-overlay" r) cfg.systemd.tmpfiles.rules;
    });

  # ========================================================================
  # runner.store.mode contract (option in modules/runner/store.nix)
  # ========================================================================
  storeModeCfg = mode: { services.nixtache.runner.store.mode = mode; };
  storeModePresent = probeOK [ self.nixosModules.runner runnerBase (storeModeCfg "overlay") ];

  scenarioStoreModeOverlay = contract
    "runner.store.mode=\"overlay\" → container has overlay-mount service, NO clone storage (RO1, read-only+overlay)"
    [ self.nixosModules.runner runnerBase (storeModeCfg "overlay") ]
    (cfg:
      let ccfg = cfg.containers."runner".config; in
      {
        hasOverlayMount = ccfg.systemd.services ? "nix-daemon-overlay-mount";
        noCloneStorage = !(ccfg.systemd.services ? "nix-daemon-storage");
      });

  scenarioStoreModeClone = contract
    "runner.store.mode=\"clone\" → container still has nix-daemon-storage (clone path preserved)"
    [ self.nixosModules.runner runnerBase (storeModeCfg "clone") ]
    (cfg:
      let ccfg = cfg.containers."runner".config; in
      {
        hasCloneStorage = ccfg.systemd.services ? "nix-daemon-storage";
      });

  # ========================================================================
  # Report aggregation
  # ========================================================================
  # Slot labels default to the detection-regex names — unset labels previously
  # produced empty GPT partition names the stateless detection could never match
  # (non-idempotent provisioning whenever the consumer omitted them).
  # (The script-level check — the defaults are BAKED into the provision
  # script — runs in the build-time bash part below, on the actual derivation.)
  scenarioPartLabelDefaults = contract
    "ab.partitions: slot labels default to nix-store_1 / _empty (P2 idempotence)"
    [ self.nixosModules.deploy-target (abPartCfg {
        slot_a = { type = "partition"; storage = "/dev/vdb"; };
        slot_b = { type = "partition"; storage = "/dev/vdb"; };
      }) ]
    (cfg: {
      slotADefault = cfg.services.nixtache.deploy-target.ab.partitions.slot_a.label == "nix-store_1";
      slotBDefault = cfg.services.nixtache.deploy-target.ab.partitions.slot_b.label == "_empty";
      provisionUnitPresent = cfg.systemd.services ? "nixtache-ab-provision";
    });

  # The provision script source (the unit's `script` attr only carries the
  # writeShellScript store path; the source text is the checkable artifact).
  # Two-step proof for the baked labels: option defaults are asserted above
  # (slotADefault/slotBDefault) + the script consumes ${…slot.label} below.
  abProvisionSource = pkgs.writeText "ab-provision.nix"
    (builtins.readFile ../modules/deploy-target/ab-provision.nix);

  # onSizeMismatch=error masks systemd-sysupdate (updates STOP until manual
  # unmask) and fails the provision unit — a silently-running sysupdate with a
  # wrong slot size would fail or truncate every update. Script-text checks run
  # in the build-time bash part below (same pattern as runner.nix).
  scenarioPartMismatchMasks = contract
    "ab.partitions: onSizeMismatch=error → unit present; mask semantics in script (S1)"
    [ self.nixosModules.deploy-target (abPartCfg { }) ]
    (cfg: {
      provisionUnitPresent = cfg.systemd.services ? "nixtache-ab-provision";
      mismatchPolicy = cfg.services.nixtache.deploy-target.ab.partitions.onSizeMismatch == "error";
    });

  scenarios = [
    scenarioPartWiring
    scenarioPartBootTargetDir
    scenarioPartDiffDisks
    scenarioPartSameDisk
    scenarioPartRegularFile
    scenarioPartAssertTypeMismatch
    scenarioPartAssertSizeMismatch
    scenarioPartAssertAutoInitRegularFile
    scenarioPartAssertBadStorage
    scenarioPartSourceUrl
    scenarioPartSourceLocal
    scenarioPartAssertVerifyNoKey
    scenarioPartAssertBothKeys
    scenarioPartVerifyKey
    scenarioPartLabelDefaults
    scenarioPartMismatchMasks
    scenarioOverlayWiring
    scenarioStoreModeOverlay
    scenarioStoreModeClone
  ];

  failed = builtins.concatMap
    (s: if builtins.all (c: c) (builtins.attrValues s.checks) then [ ] else [ s.name ])
    scenarios;
  allOk = failed == [ ];
  report = lib.concatStringsSep "\n" (lib.flatten (map
    (s:
      [ s.name ] ++ (map
        (cn: "  ${if s.checks.${cn} then "ok  " else "FAIL"}  ${cn}")
        (builtins.attrNames s.checks)))
    scenarios));
  failMsg = lib.optionalString (!allOk)
    "FAILED (contracts not yet implemented are expected red): ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "ab-contract-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
    # Forces the provision script source into the build so its text can be
    # verified (the unit's `script` attr holds only a store path).
    deps = [ abProvisionSource ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi

    script_fail=""
    src="${abProvisionSource}"
    # The script bakes the slot labels from the options (defaults proven by the
    # eval scenario above → the baked values are nix-store_1 / _empty).
    grep -qF 'LABEL_A="''${toString slotA.label}"' "$src" || script_fail="$script_fail no-label-a-bake"
    grep -qF 'LABEL_B="''${toString slotB.label}"' "$src" || script_fail="$script_fail no-label-b-bake"
    # onSizeMismatch=error: runtime-mask sysupdate (updates STOP; the provision
    # unit re-arms the mask every boot) + fail + unmask hint.
    grep -q 'systemctl mask --runtime systemd-sysupdate.service' "$src" || script_fail="$script_fail no-mask"
    grep -q 'systemctl unmask --runtime systemd-sysupdate.service' "$src" || script_fail="$script_fail no-unmask-hint"

    if [ -n "$script_fail" ]; then
      echo "FAIL: provision script text:$script_fail"
      echo "FAIL: provision script text:$script_fail" >> "$out"
      exit 1
    fi
    echo "provision script text: default labels + mask-on-mismatch OK"
  ''

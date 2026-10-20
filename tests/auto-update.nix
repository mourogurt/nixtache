# Pure-eval CONTRACT tests for the auto-update module (spec 09 — option tree
# `services.nixtache.auto-update.*`), implementing the pure-eval cases AU-1…AU-25
# of doc/archive/specs/direct-deploy/TEST-SPECS-AUTO-UPDATE.md.
#
# Wiring scenarios degrade to a named `moduleImplemented=false` check and
# assert scenarios are gated on a `modulePresent` probe when the module is
# absent — the graceful-degradation pattern of ab-contract.nix.
#
# Fast, no KVM. Exposed via checks.<system>.auto-update.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  # String, not a path literal — same rationale as tests/ab-contract.nix
  # (types.path options accept strings via coercion; a /dev/null path literal
  # breaks nullOr str options under the deep toplevel probe).
  dummySecret = "/dev/null";

  # Empty-module fallback when the module is absent, so an OPTION-missing
  # error (caught by the probes) is what surfaces, not an attrset-missing crash.
  autoMod = self.nixosModules.auto-update or ({ ... }: { });

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
    # The appliance world evaluates content-addressed (ab-image asserts it).
    nixpkgs.config.contentAddressedByDefault = true;
    # Dummy root FS + grub off: lets probeOK force toplevel.outPath without
    # firing base NixOS bootability assertions (same pattern as ab-contract.nix).
    fileSystems."/".fsType = lib.mkDefault "tmpfs";
    boot.loader.grub.enable = lib.mkDefault false;
  };

  defaultUrl = "git+https://example.invalid/org/repo.git";

  # Host flavours per test-spec §0.2.
  flakeMods = au: [
    self.nixosModules.deploy-target
    autoMod
    baseModule
    {
      services.nixtache.auto-update = lib.recursiveUpdate
        { enable = true; flake.url = defaultUrl; }
        au;
    }
  ];

  abMods = au: [
    self.nixosModules.deploy-target
    autoMod
    baseModule
    {
      # Stubs for a clean eval without full A/B prep — same pair as scenarioAb
      # in tests/deploy-target.nix. The hand-rolled transfer satisfies strict
      # A4 (the ab path needs a resolvable update source; consumer-owned
      # systemd.sysupdate transfers with a Source count).
      systemd.sysupdate.enable = true;
      systemd.sysupdate.transfers."10-nix-store".Source = {
        Path = "http://stage.test/";
        Type = "url-file";
        MatchPattern = [ "t_@v.nix-store.raw" ];
      };
      boot.loader.systemd-boot.bootCounting.enable = true;
      services.nixtache.deploy-target.ab.enable = true;
      services.nixtache.auto-update = lib.recursiveUpdate { enable = true; } au;
    }
  ];

  # Gating host: the gating unit reads services.nixtache.runner.forgejoPort, so
  # the runner module is imported for its OPTION surface only (left disabled) —
  # same trick as mkHostAb in tests/deploy-target.nix.
  gatingMods = au: [
    self.nixosModules.deploy-target
    self.nixosModules.runner
    autoMod
    baseModule
    {
      services.nixtache.runner.forgejoUrl = "http://localhost:3000";
      systemd.sysupdate.enable = true;
      systemd.sysupdate.transfers."10-nix-store".Source = {
        Path = "http://stage.test/";
        Type = "url-file";
        MatchPattern = [ "t_@v.nix-store.raw" ];
      };
      boot.loader.systemd-boot.bootCounting.enable = true;
      services.nixtache.deploy-target.ab = {
        enable = true;
        gating = true;
        forgejoApiTokenFile = dummySecret;
      };
      services.nixtache.auto-update = lib.recursiveUpdate { enable = true; } au;
    }
  ];

  probeOK = modules:
    (builtins.tryEval
      ((nixpkgs.lib.nixosSystem { inherit system modules; }).config.system.build.toplevel.outPath)
    ).success;
  evalCfg = modules: (nixpkgs.lib.nixosSystem { inherit system modules; }).config;

  # Green once the module exists and a minimal flake-path host evaluates.
  modulePresent = probeOK (flakeMods { });

  # Wiring contract: green checks if eval OK, else moduleImplemented=false
  # (red, clearly named) instead of crashing the suite.
  contract = name: modules: checksFn:
    let ok = probeOK modules; in
    {
      inherit name;
      checks = if ok then checksFn (evalCfg modules) else { moduleImplemented = false; };
    };

  # Failed-assertion messages of a bad config; [ ] when it refuses to even
  # evaluate (e.g. module still missing) — tryEval keeps the suite graceful.
  failedAssertions = modules:
    let
      msgs = map (a: a.message)
        (builtins.filter (a: !a.assertion) (evalCfg modules).assertions);
      r = builtins.tryEval (builtins.deepSeq msgs msgs);
    in
    if r.success then r.value else [ ];

  # Assert contract (A1–A8): green only when the module is present AND the bad
  # config refuses toplevel eval AND some failed assertion mentions one of the
  # hints — distinguishing a firing assertion from an attribute-missing crash
  # (test-spec §2, the A2 boundary).
  assertContract = name: modules: hints: {
    inherit name;
    checks = {
      inherit modulePresent;
      badConfigRefused = !(probeOK modules);
      assertMessage = modulePresent
        && builtins.any (m: builtins.any (h: lib.hasInfix h m) hints) (failedAssertions modules);
    };
  };

  auSvc = cfg: cfg.systemd.services."nixtache-auto-update" or { };
  auScript = cfg: (auSvc cfg).script or "";
  auTmr = cfg: cfg.systemd.timers."nixtache-auto-update" or { };

  # =========================================================================
  # §1 wiring (AU-1…AU-14)
  # =========================================================================
  scenarioAu1 = contract "AU-1: disabled by default → no units"
    (flakeMods { enable = false; })
    (cfg: {
      noService = !(cfg.systemd.services ? "nixtache-auto-update");
      noTimer = !(cfg.systemd.timers ? "nixtache-auto-update");
      noRebootTimer = !(cfg.systemd.timers ? "nixtache-auto-update-reboot");
    });

  scenarioAu2 = contract "AU-2: enable → timer+service wired, schedule defaults (flake path)"
    (flakeMods { })
    (cfg:
      let svc = auSvc cfg; tmr = auTmr cfg; in
      {
        servicePresent = cfg.systemd.services ? "nixtache-auto-update";
        serviceOneshot = svc.serviceConfig.Type or null == "oneshot";
        timerPresent = cfg.systemd.timers ? "nixtache-auto-update";
        timerWanted = lib.elem "timers.target" (tmr.wantedBy or [ ]);
        timerCalendar = tmr.timerConfig.OnCalendar or null == "daily";
        timerDelay = tmr.timerConfig.RandomizedDelaySec or null == "1h";
        timerPersistent = tmr.timerConfig.Persistent or null == true;
      });

  scenarioAu3 = contract "AU-3: dates/randomizedDelaySec/persistent propagate to the timer"
    (flakeMods { dates = "Mon 03:30"; randomizedDelaySec = "30min"; persistent = false; })
    (cfg:
      let tmr = auTmr cfg; in
      {
        calendarSet = tmr.timerConfig.OnCalendar or null == "Mon 03:30";
        delaySet = tmr.timerConfig.RandomizedDelaySec or null == "30min";
        persistentOff = tmr.timerConfig.Persistent or null == false;
      });

  scenarioAu4 = contract "AU-4: flake.* wired into the service script (ref/configuration/flags; apply-unit trigger)"
    (flakeMods {
      flake = {
        url = "git+https://example.invalid/o/r.git";
        ref = "release";
        configuration = "myhost";
        flags = [ "--refresh" ];
      };
    } ++ [ { networking.hostName = "other"; } ])
    (cfg:
      let script = auScript cfg; in
      {
        buildTarget = lib.hasInfix
          "git+https://example.invalid/o/r.git?ref=release#nixosConfigurations.myhost.config.system.build.toplevel"
          script;
        flagsInScript = lib.hasInfix "--refresh" script;
        pointerWrite = lib.hasInfix "/var/lib/nixtache/pending-system" script;
        applyTrigger = lib.hasInfix "systemctl start nixtache-apply.service" script;
        noNixosRebuild = !(lib.hasInfix "nixos-rebuild" script);
      });

  scenarioAu5 = contract "AU-5: flake.configuration = null → hostName used"
    (flakeMods { flake.configuration = null; } ++ [ { networking.hostName = "lap"; } ])
    (cfg: {
      hostNameUsed = lib.hasInfix "nixosConfigurations.lap." (auScript cfg);
    });

  scenarioAu6 = contract "AU-6: flake.ref = null → no ?ref= appended"
    (flakeMods { flake.ref = null; })
    (cfg: {
      noRefSuffix = !(lib.hasInfix "?ref=" (auScript cfg));
    });

  au7NoKeyMods = flakeMods { };
  scenarioAu7 = contract "AU-7: sshPrivateKeyFile → LoadCredential + GIT_SSH_COMMAND (null → neither)"
    (flakeMods { flake.sshPrivateKeyFile = dummySecret; })
    (cfg:
      let
        svc = auSvc cfg;
        creds = svc.serviceConfig.LoadCredential or [ ];
        text = (svc.script or "")
          + lib.concatStringsSep " " (builtins.attrValues (svc.environment or { }));
        svcNoKey = auSvc (evalCfg au7NoKeyMods);
        credsNoKey = svcNoKey.serviceConfig.LoadCredential or [ ];
        textNoKey = (svcNoKey.script or "")
          + lib.concatStringsSep " " (builtins.attrValues (svcNoKey.environment or { }));
      in
      {
        loadCredential = builtins.any (c: lib.hasInfix dummySecret c) creds;
        gitSshCommand = lib.hasInfix "GIT_SSH_COMMAND" text
          && lib.hasInfix "CREDENTIALS_DIRECTORY" text;
        noKeyNoCredential = credsNoKey == [ ];
        noKeyNoGitSsh = !(lib.hasInfix "GIT_SSH_COMMAND" textNoKey);
      });

  scenarioAu8 = contract "AU-8: method auto → flake (no ab indicators)"
    (flakeMods { })
    (cfg:
      let script = auScript cfg; in
      {
        flakePath = lib.hasInfix "nix build" script
          && !(lib.hasInfix "systemd-sysupdate.service" script);
        rebootNeverDefault = !(lib.hasInfix "systemctl reboot" script);
      });

  scenarioAu9 = contract "AU-9: method auto → ab-image (via deploy-target.ab.enable); flake.url not required"
    (abMods { })
    (cfg:
      let script = auScript cfg; in
      {
        abPath = lib.hasInfix "systemctl start systemd-sysupdate.service" script;
        noBuild = !(lib.hasInfix "nix build" script);
        journalDetect = lib.hasInfix "journalctl -u systemd-sysupdate" script;
      });

  scenarioAu10 = contract "AU-10: method auto → ab-image (via ab-image.enable, second indicator)"
    [
      self.nixosModules.deploy-target
      self.nixosModules.ab-image
      autoMod
      baseModule
      {
        # ab-image's appliance profile trips the base NixOS no-login assertion
        # under the toplevel probe; satisfy it (test-only concern).
        users.users.root.initialPassword = "";
        services.nixtache.ab-image = { enable = true; imageId = "t"; };
        services.nixtache.auto-update.enable = true;
      }
    ]
    (cfg:
      let script = auScript cfg; in
      {
        abDerived = lib.hasInfix "systemd-sysupdate.service" script
          && !(lib.hasInfix "nix build" script);
      });

  scenarioAu11a = contract "AU-11A: explicit method=flake overrides ab derive"
    (abMods { method = "flake"; flake.url = defaultUrl; })
    (cfg:
      let script = auScript cfg; in
      {
        explicitFlake = lib.hasInfix "nix build" script
          && !(lib.hasInfix "systemd-sysupdate.service" script);
      });

  # AU-11B vs A8 (AU-22) ambiguity: A8 must fire only when NO ab indicator
  # exists at all; an explicit systemd.sysupdate.enable = true counts as the
  # indicator that makes explicit method = "ab-image" legitimate (AU-22 keeps
  # sysupdate off and must fail). See test-spec AU-11 setup B.
  scenarioAu11b = contract "AU-11B: explicit method=ab-image on a non-ab host (+sysupdate stub)"
    (flakeMods { method = "ab-image"; } ++ [
      {
        systemd.sysupdate.enable = true;
        # Strict A4: the ab path needs a resolvable source — a consumer-owned
        # transfer with a Source satisfies it without the ab modules.
        systemd.sysupdate.transfers."10-nix-store".Source = {
          Path = "http://stage.test/";
          Type = "url-file";
          MatchPattern = [ "t_@v.nix-store.raw" ];
        };
      }
    ])
    (cfg: {
      explicitAb = lib.hasInfix "systemd-sysupdate.service" (auScript cfg);
    });

  scenarioAu12a = contract "AU-12A: rebootPolicy=if-needed (flake) → kernel compare + reboot call"
    (flakeMods { rebootPolicy = "if-needed"; })
    (cfg:
      let script = auScript cfg; in
      {
        kernelCompare = lib.hasInfix "/run/booted-system" script
          && lib.hasInfix "/run/current-system" script;
        rebootCall = lib.hasInfix "systemctl reboot" script;
      });

  scenarioAu12b = contract "AU-12B: rebootPolicy=if-needed (ab) → immediate reboot, no pending marker"
    (abMods { rebootPolicy = "if-needed"; })
    (cfg:
      let script = auScript cfg; in
      {
        immediateReboot = lib.hasInfix "systemctl reboot" script;
        noPendingMarker = !(lib.hasInfix "/var/lib/nixtache/reboot-pending" script);
      });

  scenarioAu13 = contract "AU-13: rebootPolicy=window → marker + nixtache-auto-update-reboot.timer"
    (flakeMods { rebootPolicy = "window"; rebootWindow = { start = "02:00"; end = "05:00"; }; })
    (cfg:
      let
        script = auScript cfg;
        rtmr = cfg.systemd.timers."nixtache-auto-update-reboot" or { };
      in
      {
        markerTouch = lib.hasInfix "/var/lib/nixtache/reboot-pending" script;
        # The reboot itself is performed by the reboot timer's service, never
        # directly by the poll service.
        noDirectReboot = !(lib.hasInfix "systemctl reboot" script);
        rebootTimerPresent = cfg.systemd.timers ? "nixtache-auto-update-reboot";
        rebootTimerCalendar = rtmr.timerConfig.OnCalendar or null == "02:00";
        rebootTimerWanted = lib.elem "timers.target" (rtmr.wantedBy or [ ]);
      });

  scenarioAu14 = contract "AU-14: gating host → ab.poll derived false (ci-driven no-op); explicit poll=true overrides"
    (gatingMods { rebootPolicy = "never"; })
    (cfg:
      let
        script = auScript cfg;
        scriptPoll = auScript (evalCfg (gatingMods { rebootPolicy = "never"; ab.poll = true; }));
      in
      {
        # Text-level check: the sysupdate trigger must be absent from the
        # no-op branch altogether (a comment/echo-only mention is tolerated by
        # the spec but not distinguishable here).
        pollDerivedFalse = lib.hasInfix "ci-driven" script
          && !(lib.hasInfix "systemctl start systemd-sysupdate.service" script);
        explicitPollTrue = lib.hasInfix "systemctl start systemd-sysupdate.service" scriptPoll;
      });

  # =========================================================================
  # §2 assert matrix (AU-15…AU-22 → A1…A8)
  # =========================================================================
  scenarioAu15 = assertContract "AU-15/A1: system.autoUpgrade.enable + auto-update → eval refuses"
    (flakeMods { } ++ [ { system.autoUpgrade.enable = true; } ])
    [ "system.autoUpgrade" ];

  scenarioAu16 = assertContract "AU-16/A2: flake path without deploy-target → eval refuses (assertion, not attr-missing)"
    [
      autoMod
      baseModule
      { services.nixtache.auto-update = { enable = true; flake.url = defaultUrl; }; }
    ]
    [ "deploy-target" "nixtache-apply" ];

  scenarioAu17 = assertContract "AU-17/A3: method flake + flake.url = null → eval refuses"
    (flakeMods { flake.url = null; })
    [ "flake.url" ];

  scenarioAu18 = assertContract "AU-18/A4: ab-image path + systemd.sysupdate off → eval refuses"
    [
      self.nixosModules.ab-image
      autoMod
      baseModule
      {
        # ab-image's appliance profile trips the base NixOS no-login assertion
        # under the toplevel probe; satisfy it so ONLY A4 fires.
        users.users.root.initialPassword = "";
        # ab-image sets sysupdate.enable plainly (priority 100) — mkForce wins.
        systemd.sysupdate.enable = lib.mkForce false;
        services.nixtache.ab-image = { enable = true; imageId = "t"; };
        services.nixtache.auto-update = { enable = true; method = "ab-image"; };
      }
    ]
    [ "systemd.sysupdate" ];

  # Strict A4 (spec 09 §7): sysupdate alone is NOT enough — the ab path also
  # needs a resolvable source (ab-image module, ab.partitions.source, or
  # consumer-owned transfers carrying a Source). None here → refuses.
  scenarioAu18b = assertContract "AU-18b/A4-strict: ab path + sysupdate on + NO source anywhere → eval refuses"
    [
      self.nixosModules.deploy-target
      autoMod
      baseModule
      {
        systemd.sysupdate.enable = true;
        boot.loader.systemd-boot.bootCounting.enable = true;
        services.nixtache.deploy-target.ab.enable = true;
        services.nixtache.auto-update = { enable = true; method = "ab-image"; };
      }
    ]
    [ "resolvable update source" ];

  scenarioAu19 = assertContract "AU-19/A5: rebootPolicy=window + empty window (start==end) → eval refuses"
    (flakeMods { rebootPolicy = "window"; rebootWindow = { start = "02:00"; end = "02:00"; }; })
    [ "rebootWindow" ];

  scenarioAu20 = assertContract "AU-20/A6: gating host + rebootPolicy=if-needed → eval refuses"
    (gatingMods { rebootPolicy = "if-needed"; })
    [ "gating" "rebootPolicy" ];

  # A7 is a lib.warn, not an assertion: nix eval does not expose warnings, so
  # the contract is (a) eval still succeeds and (b) the ab branch is active.
  # The warning itself is verified by eyeballing the build log (spec marks
  # AU-21 📋/partial).
  scenarioAu21 = contract "AU-21/A7 (partial): ab path + Transfer.Reboot=yes → eval PASSES (lib.warn contract)"
    (abMods { } ++ [ { systemd.sysupdate.transfers."10-nix-store".Transfer.Reboot = "yes"; } ])
    (cfg: {
      hostEvals = true;
      abPathActive = lib.hasInfix "systemctl start systemd-sysupdate.service" (auScript cfg);
    });

  scenarioAu22 = assertContract "AU-22/A8: explicit method=ab-image with no ab indicators → eval refuses"
    (flakeMods { method = "ab-image"; } ++ [ { systemd.sysupdate.enable = false; } ])
    [ "ab-image" ];

  # =========================================================================
  # §3 precedence / idempotency (AU-23…AU-25)
  # =========================================================================
  scenarioAu23 = contract "AU-23: CI-pending skip branch (pointer checked before write)"
    (flakeMods { })
    (cfg:
      let script = auScript cfg; in
      {
        # Quoted and unquoted existence tests both satisfy "checked before write".
        pendingCheck = lib.hasInfix ''-f "/var/lib/nixtache/pending-system"'' script
          || lib.hasInfix "-f /var/lib/nixtache/pending-system" script;
        skipMarker = lib.hasInfix "skipping" script;
      });

  scenarioAu24 = contract "AU-24: unchanged-toplevel no-op branch"
    (flakeMods { })
    (cfg:
      let script = auScript cfg; in
      {
        currentSystemCompare = lib.hasInfix "/run/current-system" script;
        alreadyMarker = lib.hasInfix "already at" script;
      });

  scenarioAu25 = contract "AU-25: atomic pointer write (tmp + rename, no direct redirect)"
    (flakeMods { })
    (cfg:
      let script = auScript cfg; in
      {
        tmpFile = lib.hasInfix "pending-system.tmp" script;
        rename = lib.hasInfix "mv" script;
        noDirectWrite = !(lib.hasInfix "> /var/lib/nixtache/pending-system" script);
      });

  scenarios = [
    scenarioAu1
    scenarioAu2
    scenarioAu3
    scenarioAu4
    scenarioAu5
    scenarioAu6
    scenarioAu7
    scenarioAu8
    scenarioAu9
    scenarioAu10
    scenarioAu11a
    scenarioAu11b
    scenarioAu12a
    scenarioAu12b
    scenarioAu13
    scenarioAu14
    scenarioAu15
    scenarioAu16
    scenarioAu17
    scenarioAu18
    scenarioAu18b
    scenarioAu19
    scenarioAu20
    scenarioAu21
    scenarioAu22
    scenarioAu23
    scenarioAu24
    scenarioAu25
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
    "FAILED (auto-update contracts not yet implemented are expected red): ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "auto-update-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

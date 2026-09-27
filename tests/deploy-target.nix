# Pure-evaluation tests for the deploy-target receiving module (`nixosModules.deploy-target`).
#
# V2 design (no deploy-rs, no sudo/doas/run0): each scenario imports the module
# and asserts the WIRING without running any service — that the apply unit is
# generated, the polkit rule is present, the deploy user is provisioned, and the
# Tier-0 health-check oneshot is wired before boot-complete.target.
#
#   - apply      → nixtache-apply.service exists (Type=oneshot), its script
#                  contains the criticalUnits probe + rollback, polkit rule
#                  authorizes the deploy user to start ONLY that unit;
#   - user       → deployUser.autoProvision=true creates the user + key + group;
#                  autoProvision=false with no user fires the assertion;
#   - tier0      → criticalUnits non-empty wires nixtache-health-check.service
#                  Before= + RequiredBy= boot-complete.target; default timeout 300;
#   - timeout    → healthCheckTimeout propagates into the apply + health-check scripts.
#
# Exposed via the flake as `checks.<system>.deploy-target`.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Minimal target config shared by every scenario.
  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    services.nixtache.deploy-target = {
      enable = true;
    };
  };

  mkHost = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.deploy-target
        baseModule
        extra
      ];
    };

  # Variant that ALSO imports the runner module — used by ab-image scenarios that
  # touch `gating = true`: the gating unit reads `services.nixtache.runner.forgejoPort`
  # (the runner-host self-update host runs BOTH modules). The runner module is
  # left `enable = false` here; we only need its OPTION surface (forgejoPort) to
  # exist so the gating script evaluates. forgejoUrl is set so the forgejoPort
  # default (parsed from it) resolves to 3000.
  mkHostAb = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.deploy-target
        self.nixosModules.runner
        baseModule
        { services.nixtache.runner.forgejoUrl = "http://localhost:3000"; }
        extra
      ];
    };

  servicesOf = host: host.config.systemd.services;
  has = set: name: set ? ${name};

  # First-occurrence position of `pat` in `s` (used to assert script ORDER:
  # e.g. rm-of-ab-pending AFTER the sysupdate trigger). lib.split takes a regex
  # — the patterns below are regex-safe.
  posOf = pat: s: lib.stringLength (builtins.head (lib.split pat s));

  # --- scenario A: apply unit + polkit wired (default deploy user) ----------
  hostApply = mkHost {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
    };
  };
  svcApply = servicesOf hostApply;
  dryScript = svcApply."nixtache-apply-dry".script or "";
  scenarioApply = {
    name = "apply units + polkit wired; deploy user default name";
    checks = {
      hasApplyUnit = has svcApply "nixtache-apply";
      applyTypeOneshot = svcApply."nixtache-apply".serviceConfig.Type == "oneshot";
      # Self-restart guard: a deploy that changes the apply unit itself must
      # not let switch-to-configuration restart the running apply oneshot
      # (that cancels the start job mid-switch — "Job for nixtache-apply.service
      # canceled").
      applyNoRestartIfChanged = svcApply."nixtache-apply".restartIfChanged == false;
      dryNoRestartIfChanged = svcApply."nixtache-apply-dry".restartIfChanged == false;
      # dry-apply unit (D11): PR-preview counterpart — diff only, no mutation
      hasDryUnit = has svcApply "nixtache-apply-dry";
      dryTypeOneshot = svcApply."nixtache-apply-dry".serviceConfig.Type == "oneshot";
      dryScriptActivates = lib.hasInfix "dry-activate" dryScript;
      dryScriptOwnPointer = lib.hasInfix "pending-dry" dryScript;
      # read-only: no profile mutation in the dry path
      dryScriptNoProfileSet = !(lib.hasInfix "nix-env" dryScript);
      polkitEnabled = hostApply.config.security.polkit.enable == true;
      polkitRulePresent = hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or null != null;
      polkitRuleNamesUser =
        lib.hasInfix "\"nixos-deploy\""
          (hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or "");
      polkitRuleNamesUnit =
        lib.hasInfix "nixtache-apply.service"
          (hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or "");
      polkitRuleNamesDryUnit =
        lib.hasInfix "nixtache-apply-dry.service"
          (hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or "");
      tmpfilesStateDir =
        lib.any (r: lib.hasInfix "/var/lib/nixtache" r)
          hostApply.config.systemd.tmpfiles.rules;
      deployGroup = hostApply.config.users.groups ? nixtache-deploy;
      # deploy user NOT auto-created here (autoProvision defaults true) — it IS:
      deployUserCreated = hostApply.config.users.users ? nixos-deploy;
      deployUserInGroup =
        hostApply.config.users.users.nixos-deploy.group or null == "nixtache-deploy"
        || lib.elem "nixtache-deploy"
          (hostApply.config.users.users.nixos-deploy.extraGroups or [ ]);
      deployUserTrusted =
        lib.elem "nixos-deploy" hostApply.config.nix.settings.trusted-users;
      # SYSTEM user: invisible in display managers (SDDM lists uid >= 1000 /
      # normal users only), never isNormalUser.
      deployUserIsSystem = hostApply.config.users.users.nixos-deploy.isSystemUser == true;
      deployUserNotNormal = hostApply.config.users.users.nixos-deploy.isNormalUser or false == false;
      # gate prefix on the provisioned key line (sshGate default "gate")
      deployKeyGated = lib.hasPrefix "restrict,command=" (lib.head
        hostApply.config.users.users.nixos-deploy.openssh.authorizedKeys.keys);
    };
  };

  # --- scenario A2: nixTrust option REMOVED → setting it refuses eval --------
  tryNixTrust = builtins.tryEval
    (mkHost {
      services.nixtache.deploy-target.deployUser = {
        name = "nixos-deploy";
        authorizedKey = "ssh-ed25519 AAAA...test";
        nixTrust = false;
      };
    }).config.system.build.toplevel.outPath;
  scenarioNixTrustRemoved = {
    name = "deployUser.nixTrust removed → setting it is an unknown-option eval error";
    checks = { refused = !tryNixTrust.success; };
  };

  # --- scenario A3: sshGate modes --------------------------------------------
  hostGateRestrict = mkHost {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
      sshGate = "restrict";
    };
  };
  hostGateNone = mkHost {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
      sshGate = "none";
    };
  };
  scenarioGateModes = {
    name = "sshGate=restrict → restrict-only prefix; sshGate=none → plain key line";
    checks = {
      restrictOnly = lib.hasPrefix "restrict ssh-ed25519"
        (lib.head hostGateRestrict.config.users.users.nixos-deploy.openssh.authorizedKeys.keys);
      noCommandInRestrict = !(lib.hasInfix "command="
        (lib.head hostGateRestrict.config.users.users.nixos-deploy.openssh.authorizedKeys.keys));
      plainKey = (lib.head hostGateNone.config.users.users.nixos-deploy.openssh.authorizedKeys.keys)
        == "ssh-ed25519 AAAA...test";
    };
  };

  # --- scenario B: criticalUnits → Tier-0 health-check + apply probe ---------
  hostCrit = mkHost {
    services.nixtache.deploy-target.criticalUnits = [ "amneziawg-wg0.service" "forgejo.service" ];
    services.nixtache.deploy-target.healthCheckTimeout = 600;
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
    };
  };
  svcCrit = servicesOf hostCrit;
  applyScript = svcCrit."nixtache-apply".script;
  hcScript = svcCrit."nixtache-health-check".script;
  scenarioCritical = {
    name = "criticalUnits wire Tier-0 health-check + embed in apply probe; timeout propagates";
    checks = {
      hasHealthCheck = has svcCrit "nixtache-health-check";
      hcBeforeBootComplete = lib.elem "boot-complete.target" (svcCrit."nixtache-health-check".before or [ ]);
      hcRequiredByBootComplete = lib.elem "boot-complete.target" (svcCrit."nixtache-health-check".requiredBy or [ ]);
      applyProbesAmnezia = lib.hasInfix "amneziawg-wg0.service" applyScript;
      applyProbesForgejo = lib.hasInfix "forgejo.service" applyScript;
      applyHasTimeout600 = lib.hasInfix "600" applyScript;
      hcHasTimeout600 = lib.hasInfix "600" hcScript;
      # Probes must NOT use `is-active --wait`: it blocks indefinitely on a
      # unit stuck in "activating", defeating the deadline loop (hangs the
      # apply/health-check unit — and CI — forever). The poll loop is the wait.
      applyNoIsActiveWait = !(lib.hasInfix "is-active --quiet --wait" applyScript);
      hcNoIsActiveWait = !(lib.hasInfix "is-active --quiet --wait" hcScript);
      applyHasRollback = lib.hasInfix "rollback" applyScript;
      # Rollback re-activates the PRE-APPLY closure — never /run/current-system
      # (which post-switch points at the broken new system).
      rollbackReactivatesPrev = lib.hasInfix "\"$prev/bin/switch-to-configuration\" switch" applyScript;
      noCurrentSystemRollback = !(lib.hasInfix "/run/current-system/bin/switch-to-configuration" applyScript);
    };
  };

  # --- scenario C: empty criticalUnits → no health-check, apply skips probe --
  hostNoCrit = mkHost {
    services.nixtache.deploy-target.criticalUnits = [ ];
  };
  svcNoCrit = servicesOf hostNoCrit;
  scenarioNoCritical = {
    name = "empty criticalUnits → no Tier-0 health-check; apply probe branch skipped";
    checks = {
      noHealthCheck = !(has svcNoCrit "nixtache-health-check");
      applyStillPresent = has svcNoCrit "nixtache-apply";
    };
  };

  # --- scenario D: default healthCheckTimeout = 300 -------------------------
  hostDefaultTimeout = mkHost { };
  scenarioDefaultTimeout = {
    name = "healthCheckTimeout default = 300";
    checks = {
      defaultTimeout = hostDefaultTimeout.config.services.nixtache.deploy-target.healthCheckTimeout == 300;
    };
  };

  # --- scenario E: autoProvision=false without user → assertion fires -------
  tryAutoOff = builtins.tryEval
    (mkHost {
      services.nixtache.deploy-target.deployUser = {
        name = "ghost";
        authorizedKey = "ssh-ed25519 AAAA...test";
        autoProvision = false;
      };
    }).config.system.build.toplevel.outPath;
  scenarioAutoOffAssert = {
    name = "autoProvision=false + absent user → eval refuses (assertion)";
    checks = { refused = !tryAutoOff.success; };
  };

  # --- scenario E1.5: manual user (autoProvision=false) → warnings ------------
  # A hand-managed NORMAL user is visible in SDDM → warning; with sshGate =
  # "gate" the module also suggests the ready-made gate prefix for the key.
  hostManualUser = mkHost {
    users.users.ghost = {
      isNormalUser = true;
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA...manual" ];
    };
    services.nixtache.deploy-target.deployUser = {
      name = "ghost";
      authorizedKey = "ssh-ed25519 AAAA...manual";
      autoProvision = false;
    };
  };
  warningsManual = hostManualUser.config.warnings;
  scenarioManualUserWarns = {
    name = "autoProvision=false + hand-managed normal user → DM-visibility + gate-prefix warnings";
    checks = {
      warnsNormalUser = lib.any (lib.hasInfix "visible in graphical login screens") warningsManual;
      warnsGatePrefix = lib.any (lib.hasInfix "restrict,command=") warningsManual;
    };
  };

  # --- scenario D2: criticalUnits + systemd-boot without bootCounting → warn -
  hostBootCountingOff = mkHost {
    services.nixtache.deploy-target.criticalUnits = [ "sshd.service" ];
    boot.loader.systemd-boot.enable = true;
    # bootCounting intentionally NOT enabled
  };
  scenarioBootCountingWarn = {
    name = "criticalUnits + systemd-boot + bootCounting off → Tier-0 rollback warning";
    checks = {
      warnsBootCounting = lib.any (lib.hasInfix "bootCounting")
        hostBootCountingOff.config.warnings;
    };
  };

  # --- scenario E2: deployUser=null (timer-only target) → group + dir exist -
  # The pointer dir's tmpfiles rule references the `nixtache-deploy` group; it
  # must exist even without a deploy user (auto-update-only targets).
  hostNoUser = mkHost {
    services.nixtache.deploy-target.deployUser = null;
  };
  scenarioNoUser = {
    name = "deployUser=null → nixtache-deploy group + pointer dir still provisioned";
    checks = {
      groupExists = hostNoUser.config.users.groups ? nixtache-deploy;
      tmpfilesStateDir =
        lib.any (r: lib.hasInfix "/var/lib/nixtache" r)
          hostNoUser.config.systemd.tmpfiles.rules;
      applyStillPresent = has (servicesOf hostNoUser) "nixtache-apply";
    };
  };

  # --- ab-image scenarios (Batch E: services.nixtache.deploy-target.ab.*) ----
  # ab.enable wires a polkit rule authorizing the deploy user to start the ab
  # units (systemd-sysupdate, its -reboot variant, nixtache-ab-apply). Requires
  # the consumer to have enabled systemd.sysupdate + bootCounting (asserted).
  hostAb = mkHost {
    services.nixtache.deploy-target.ab.enable = true;
    systemd.sysupdate.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;
  };
  polkitAbRule = hostAb.config.environment.etc."polkit-1/rules.d/49-nixtache-ab.rules".text or "";
  scenarioAb = {
    name = "ab.enable=true (+sysupdate+bootCounting) → ab polkit rule authorizes sysupdate(+reboot) + nixtache-ab-apply (start only)";
    checks = {
      polkitAbPresent = polkitAbRule != "";
      polkitAbSysupdate = lib.hasInfix "\"systemd-sysupdate.service\"" polkitAbRule;
      polkitAbSysupdateReboot = lib.hasInfix "\"systemd-sysupdate-reboot.service\"" polkitAbRule;
      polkitAbApply = lib.hasInfix "\"nixtache-ab-apply.service\"" polkitAbRule;
      polkitAbStartOnly = lib.hasInfix "\"start\"" polkitAbRule;
      # gating off (default) → no nixtache-ab-apply path/service provisioned
      noAbPath = !(hostAb.config.systemd.paths ? "nixtache-ab-apply");
      noAbService = !(hostAb.config.systemd.services ? "nixtache-ab-apply");
    };
  };

  # ab.gating=true (runner-host self-update) → idle-gated nixtache-ab-apply
  # path + service wired: watches ab-pending, polls Forgejo runner idle, then
  # triggers systemd-sysupdate.
  hostAbGating = mkHostAb {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
    };
    services.nixtache.deploy-target.ab = {
      enable = true;
      gating = true;
      forgejoApiTokenFile = /dev/null;
      idleWaitTimeout = 600;
    };
    systemd.sysupdate.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;
  };
  svcAbGating = hostAbGating.config.systemd;
  abApplyScript = svcAbGating.services."nixtache-ab-apply".script;
  scenarioAbGating = {
    name = "ab.gating=true → nixtache-ab-apply path+service wired, idle-poll + forgejoPort + sysupdate trigger in script";
    checks = {
      hasAbPath = svcAbGating.paths ? "nixtache-ab-apply";
      abPathWatches = svcAbGating.paths."nixtache-ab-apply".pathConfig.PathExists or null == "/var/lib/nixtache/ab-pending";
      hasAbService = svcAbGating.services ? "nixtache-ab-apply";
      abServiceOneshot = svcAbGating.services."nixtache-ab-apply".serviceConfig.Type == "oneshot";
      # forgejoPort (3000, parsed from the runner module's forgejoUrl) reaches the script
      scriptHasForgejoPort = lib.hasInfix ":3000/api/v1/actions/runners" abApplyScript;
      # idle-poll loop + sysupdate-reboot trigger present (the -reboot variant:
      # writes the inactive slot AND reboots — plain sysupdate never reboots)
      scriptPollsBusy = lib.hasInfix "busy" abApplyScript;
      scriptTriggersSysupdateReboot = lib.hasInfix "systemctl start systemd-sysupdate-reboot.service" abApplyScript;
      # the pending flag is consumed ONLY after a successful start (retry-safe)
      rmAfterSuccessfulStart =
        (posOf "systemctl start systemd-sysupdate-reboot" abApplyScript)
          < (posOf "rm -f /var/lib/nixtache/ab-pending" abApplyScript);
      scriptKeepsPendingOnFail = lib.hasInfix "for retry" abApplyScript;
      # idleWaitTimeout propagates into the script (600s set above)
      scriptHasTimeout = lib.hasInfix "600" abApplyScript;
      # Forgejo API token mounted via LoadCredential
      scriptLoadsToken = lib.hasInfix "forgejo-api" (lib.concatStringsSep ","
        (svcAbGating.services."nixtache-ab-apply".serviceConfig.LoadCredential or [ ]));
    };
  };

  # ab.enable without systemd.sysupdate → eval refuses.
  tryAbNoSysupdate = builtins.tryEval
    (mkHost { services.nixtache.deploy-target.ab.enable = true; })
      .config.system.build.toplevel.outPath;
  scenarioAbAssertNoSysupdate = {
    name = "ab.enable without systemd.sysupdate.enable → eval refuses (assertion)";
    checks = { refused = !tryAbNoSysupdate.success; };
  };

  # ab.gating=true without forgejoApiTokenFile → eval refuses.
  tryAbGatingNoToken = builtins.tryEval
    (mkHostAb {
      services.nixtache.deploy-target.ab = {
        enable = true;
        gating = true;
      };
      systemd.sysupdate.enable = true;
      boot.loader.systemd-boot.bootCounting.enable = true;
    }).config.system.build.toplevel.outPath;
  scenarioAbGatingAssertNoToken = {
    name = "ab.gating=true without forgejoApiTokenFile → eval refuses (assertion)";
    checks = { refused = !tryAbGatingNoToken.success; };
  };

  scenarios = [
    scenarioApply
    scenarioNixTrustRemoved
    scenarioGateModes
    scenarioCritical
    scenarioNoCritical
    scenarioDefaultTimeout
    scenarioAutoOffAssert
    scenarioManualUserWarns
    scenarioBootCountingWarn
    scenarioNoUser
    scenarioAb
    scenarioAbGating
    scenarioAbAssertNoSysupdate
    scenarioAbGatingAssertNoToken
  ];

  failed = builtins.concatMap
    (s:
      if builtins.all (c: c) (builtins.attrValues s.checks)
      then [ ]
      else [ s.name ]
    )
    scenarios;

  allOk = failed == [ ];

  report = lib.concatStringsSep "\n" (lib.flatten (map
    (s:
      [ s.name ] ++ (map
        (cn: "  ${if s.checks.${cn} then "ok  " else "FAIL"}  ${cn}")
        (builtins.attrNames s.checks))
    )
    scenarios));

  failMsg = lib.optionalString (!allOk) "FAILED: ${lib.concatStringsSep ", " failed}";
in
pkgs.runCommand "deploy-target-module-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then
      echo
      cat "$failMsgPath"
      printf '\n%s\n' "$(<$failMsgPath)" >> "$out"
      exit 1
    fi
  ''

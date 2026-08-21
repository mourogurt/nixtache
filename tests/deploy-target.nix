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

  # --- scenario A: apply unit + polkit wired (default deploy user) ----------
  hostApply = mkHost {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
    };
  };
  svcApply = servicesOf hostApply;
  scenarioApply = {
    name = "apply unit + polkit wired; deploy user default name";
    checks = {
      hasApplyUnit = has svcApply "nixtache-apply";
      applyTypeOneshot = svcApply."nixtache-apply".serviceConfig.Type == "oneshot";
      polkitEnabled = hostApply.config.security.polkit.enable == true;
      polkitRulePresent = hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or null != null;
      polkitRuleNamesUser =
        lib.hasInfix "\"nixos-deploy\""
          (hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or "");
      polkitRuleNamesUnit =
        lib.hasInfix "nixtache-apply.service"
          (hostApply.config.environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text or "");
      tmpfilesStateDir =
        lib.any (r: lib.hasInfix "/var/lib/nixtache" r)
          hostApply.config.systemd.tmpfiles.rules;
      deployGroup = hostApply.config.users.groups ? nixtache-deploy;
      # deploy user NOT auto-created here (autoProvision defaults true) — it IS:
      deployUserCreated = hostApply.config.users.users ? nixos-deploy;
      deployUserInGroup =
        lib.elem "nixtache-deploy"
          (hostApply.config.users.users.nixos-deploy.extraGroups or [ ]);
      deployUserTrusted =
        lib.elem "nixos-deploy" hostApply.config.nix.settings.trusted-users;
    };
  };

  # --- scenario A2: nixTrust=false → deploy user stays untrusted ------------
  hostNoTrust = mkHost {
    services.nixtache.deploy-target.deployUser = {
      name = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA...test";
      nixTrust = false;
    };
  };
  scenarioNoTrust = {
    name = "deployUser.nixTrust=false → deploy user NOT in nix.settings.trusted-users";
    checks = {
      notTrusted = !(lib.elem "nixos-deploy" hostNoTrust.config.nix.settings.trusted-users);
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
      applyHasRollback = lib.hasInfix "rollback" applyScript;
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
  # ab.enable wires a polkit rule authorizing the deploy user to start the two
  # ab-image units (systemd-sysupdate + nixtache-ab-apply). Requires the consumer
  # to have enabled systemd.sysupdate + bootCounting (asserted).
  hostAb = mkHost {
    services.nixtache.deploy-target.ab.enable = true;
    systemd.sysupdate.enable = true;
    boot.loader.systemd-boot.bootCounting.enable = true;
  };
  polkitAbRule = hostAb.config.environment.etc."polkit-1/rules.d/49-nixtache-ab.rules".text or "";
  scenarioAb = {
    name = "ab.enable=true (+sysupdate+bootCounting) → ab polkit rule authorizes sysupdate + nixtache-ab-apply (start only)";
    checks = {
      polkitAbPresent = polkitAbRule != "";
      polkitAbSysupdate = lib.hasInfix "\"systemd-sysupdate.service\"" polkitAbRule;
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
      # idle-poll loop + sysupdate trigger present
      scriptPollsBusy = lib.hasInfix "busy" abApplyScript;
      scriptTriggersSysupdate = lib.hasInfix "systemctl start systemd-sysupdate.service" abApplyScript;
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
    scenarioNoTrust
    scenarioCritical
    scenarioNoCritical
    scenarioDefaultTimeout
    scenarioAutoOffAssert
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

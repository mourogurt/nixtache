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

  scenarios = [
    scenarioApply
    scenarioCritical
    scenarioNoCritical
    scenarioDefaultTimeout
    scenarioAutoOffAssert
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

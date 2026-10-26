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
#   - timeout    → healthCheckTimeout propagates into the apply + health-check scripts;
#   - minFreeBytes → default/custom/refused eval + the apply unit's low-disk
#                  guard BEHAVIOR (drives the real unit script with a stubbed df)
#                  and the SSH gate's exact-match free-space entry (drives the
#                  real gate script extracted from the provisioned key line).
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

  # --- scenario F: minFreeBytes option + apply-unit guard wiring -------------
  hostMinFree = mkHost {
    services.nixtache.deploy-target.minFreeBytes = 123456789;
  };
  applyScriptMinFree = (servicesOf hostMinFree)."nixtache-apply".script;
  # 0 disables the guard: evaluates fine and the script omits the df check.
  hostMinFreeZero = mkHost {
    services.nixtache.deploy-target.minFreeBytes = 0;
  };
  applyScriptZero = (servicesOf hostMinFreeZero)."nixtache-apply".script;
  scenarioMinFree = {
    name = "minFreeBytes: default 5 GiB, custom round-trips into the guard, guard precedes profile set, dry unit exempt, 0 disables";
    checks = {
      defaultIs5GiB = hostDefaultTimeout.config.services.nixtache.deploy-target.minFreeBytes == 5 * 1024 * 1024 * 1024;
      customRoundTrips = hostMinFree.config.services.nixtache.deploy-target.minFreeBytes == 123456789;
      customInScript = lib.hasInfix "below minFreeBytes (123456789)" applyScriptMinFree;
      defaultInScript = lib.hasInfix "below minFreeBytes (5368709120)" (servicesOf hostDefaultTimeout)."nixtache-apply".script;
      # The guard runs BEFORE the profile-set step (the rollback() helper
      # textually precedes it, so anchor on the step-1 marker, not nix-env).
      guardBeforeProfileSet =
        (posOf "df -B1 --output=avail" applyScriptMinFree) < (posOf "set system profile" applyScriptMinFree);
      # The dry-apply unit is exempt: dry-activate mutates nothing.
      dryExempt = !(lib.hasInfix "df -B1" dryScript);
      zeroEvaluates = hostMinFreeZero.config.services.nixtache.deploy-target.minFreeBytes == 0;
      zeroOmitsGuard = !(lib.hasInfix "df -B1" applyScriptZero);
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
  abUpdateScript = hostAb.config.systemd.services."nixtache-ab-update".script or "";
  scenarioAb = {
    name = "ab.enable=true (+sysupdate+bootCounting) → ab polkit rule + install-then-reboot nixtache-ab-update unit";
    checks = {
      polkitAbPresent = polkitAbRule != "";
      polkitAbSysupdate = lib.hasInfix "\"systemd-sysupdate.service\"" polkitAbRule;
      polkitAbSysupdateReboot = lib.hasInfix "\"systemd-sysupdate-reboot.service\"" polkitAbRule;
      polkitAbUpdate = lib.hasInfix "\"nixtache-ab-update.service\"" polkitAbRule;
      polkitAbApply = lib.hasInfix "\"nixtache-ab-apply.service\"" polkitAbRule;
      polkitAbStartOnly = lib.hasInfix "\"start\"" polkitAbRule;
      # nixtache-ab-update ships for EVERY ab target (the remote CI trigger
      # starts it over SSH); it is a oneshot that waits for the update run to
      # finish and starts the reboot leg only on install evidence.
      hasAbUpdate = hostAb.config.systemd.services ? "nixtache-ab-update";
      abUpdateOneshot = hostAb.config.systemd.services."nixtache-ab-update".serviceConfig.Type == "oneshot";
      abUpdateWaitsForCompletion = lib.hasInfix "while systemctl is-active --quiet systemd-sysupdate.service" abUpdateScript;
      abUpdateQueriesCanonicalUnit = lib.hasInfix "-u systemd-sysupdate-update.service" abUpdateScript;
      abUpdateRebootGatedOnEvidence =
        (posOf "Successfully installed" abUpdateScript)
          < (posOf "systemd-sysupdate-reboot.service" abUpdateScript);
      abUpdateNoRebootOnNothing = lib.hasInfix "installed NOTHING — not rebooting" abUpdateScript;
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
      # idle-poll loop + the delegation: apply waits for runner idle, then
      # starts nixtache-ab-update (oneshot: update to completion, reboot only
      # on install evidence — the ordering contract lives in that unit, see
      # scenarioAb's checks)
      scriptPollsBusy = lib.hasInfix "busy" abApplyScript;
      scriptDelegatesAbUpdate = lib.hasInfix "systemctl start nixtache-ab-update.service" abApplyScript;
      # the pending flag is consumed ONLY after the apply succeeded (the
      # slot write is what the flag guards — a deferred reboot must not
      # re-trigger an already-applied update)
      rmAfterSuccessfulUpdate =
        (posOf "systemctl start nixtache-ab-update.service" abApplyScript)
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
    scenarioMinFree
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

  # --- behavioral: drive the REAL apply-unit script with a stubbed df --------
  # The unit text comes from the evaluated config (hostApply — default
  # minFreeBytes = 5 GiB); its absolute paths are redirected into the sandbox
  # and nix-env / switch-to-configuration are stubs that only log their
  # invocation, so "profile untouched" is observable.
  applyScriptFile = pkgs.writeText "nixtache-apply-script" svcApply."nixtache-apply".script;
  applyGuardTest = pkgs.runCommand "apply-guard-test" { } ''
    set -u
    work=$TMPDIR/guard
    mkdir -p "$work/bin" "$work/state" "$work/profiles" "$work/fake-top/bin" "$work/prev-system"

    sed -e "s|/var/lib/nixtache|$work/state|g" \
        -e "s|/nix/var/nix/profiles|$work/profiles|g" \
        ${applyScriptFile} > "$work/apply.sh"

    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GUARD_WORK/nix-env.log"' > "$work/bin/nix-env"
    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$GUARD_WORK/switch.log"' > "$work/fake-top/bin/switch-to-configuration"
    chmod +x "$work/bin/nix-env" "$work/fake-top/bin/switch-to-configuration"

    echo "$work/fake-top" > "$work/state/pending-system"
    ln -s "$work/prev-system" "$work/profiles/system"

    run_apply() {
      env GUARD_WORK="$work" PATH="$work/bin:$PATH" bash "$work/apply.sh" \
        > "$work/$1.out" 2> "$work/$1.err" && rc=0 || rc=$?
      echo "$rc"
    }

    echo "== healthy target (df reports ~93 GiB free) =="
    printf '%s\n' '#!/bin/sh' 'echo 99999999999' > "$work/bin/df"
    chmod +x "$work/bin/df"
    rc=$(run_apply healthy)
    [ "$rc" -eq 0 ] || { echo "FAIL: healthy run exited $rc"; cat "$work/healthy.out" "$work/healthy.err"; exit 1; }
    [ -f "$work/nix-env.log" ] || { echo "FAIL: healthy run did not set the profile"; exit 1; }
    [ -f "$work/switch.log" ] || { echo "FAIL: healthy run did not switch"; exit 1; }
    [ ! -e "$work/state/pending-system" ] || { echo "FAIL: healthy run left the pointer behind"; exit 1; }
    echo "ok: healthy run activates (profile set, switch, pointer consumed)"

    echo "== low-disk target (df reports 1 MB free) =="
    printf '%s\n' '#!/bin/sh' 'echo 1000000' > "$work/bin/df"
    rm -f "$work/nix-env.log" "$work/switch.log"
    echo "$work/fake-top" > "$work/state/pending-system"
    rc=$(run_apply low)
    [ "$rc" -eq 1 ] || { echo "FAIL: low-disk run exited $rc (want 1)"; cat "$work/low.out" "$work/low.err"; exit 1; }
    [ ! -f "$work/nix-env.log" ] || { echo "FAIL: low-disk refusal touched the system profile"; exit 1; }
    [ ! -f "$work/switch.log" ] || { echo "FAIL: low-disk refusal ran switch-to-configuration"; exit 1; }
    [ ! -e "$work/state/pending-system" ] || { echo "FAIL: low-disk refusal must consume the pointer"; exit 1; }
    [ "$(readlink "$work/profiles/system")" = "$work/prev-system" ] || { echo "FAIL: low-disk refusal changed the profile symlink"; exit 1; }
    grep -q "5368709120" "$work/low.err" || { echo "FAIL: refusal must name the threshold bytes"; cat "$work/low.err"; exit 1; }
    grep -q "nix-collect-garbage" "$work/low.err" || { echo "FAIL: refusal must hint at garbage collection"; cat "$work/low.err"; exit 1; }
    echo "ok: low-disk refusal — no mutation, pointer consumed, threshold + GC hint logged"

    echo "== df unparseable — refuse WITHOUT consuming the pointer =="
    printf '%s\n' '#!/bin/sh' 'echo garbage' > "$work/bin/df"
    echo "$work/fake-top" > "$work/state/pending-system"
    rc=$(run_apply baddf)
    [ "$rc" -eq 1 ] || { echo "FAIL: unparseable-df run exited $rc (want 1)"; exit 1; }
    [ -e "$work/state/pending-system" ] || { echo "FAIL: df failure must keep the pointer for a retry"; exit 1; }
    [ ! -f "$work/nix-env.log" ] || { echo "FAIL: df failure touched the system profile"; exit 1; }
    echo "ok: df failure refuses without consuming the pointer"

    echo "apply-guard: all scenarios passed" > "$out"
  '';

  # --- behavioral: the SSH gate's exact-match free-space entry ---------------
  # The gate script is extracted from the provisioned key line of hostApply
  # (`restrict,command="<store path>" ssh-ed25519 ...`) — the REAL artifact the
  # target's sshd would force on the deploy key.
  gateScriptPath = lib.elemAt (lib.splitString "\"" (lib.head
    hostApply.config.users.users.nixos-deploy.openssh.authorizedKeys.keys)) 1;
  gateTest = pkgs.runCommand "ssh-gate-df-test" { } ''
    set -u
    rc_of() {
      SSH_ORIGINAL_COMMAND="$1" ${gateScriptPath} > "$TMPDIR/g.out" 2> "$TMPDIR/g.err" && rc=0 || rc=$?
      echo "$rc"
    }
    fails=""

    rc=$(rc_of "df -B1 --output=avail /nix/store")
    if [ "$rc" -eq 0 ] && grep -qE '^[0-9]+$' "$TMPDIR/g.out"; then
      echo "ok: exact free-space query passes the gate (byte output)"
    else
      echo "FAIL: exact query rejected (rc=$rc)"; cat "$TMPDIR/g.out" "$TMPDIR/g.err"; fails=1
    fi

    rc=$(rc_of "true")
    if [ "$rc" -eq 0 ]; then
      echo "ok: 'true' probe still allowed"
    else
      echo "FAIL: 'true' probe rejected"; fails=1
    fi

    reject() {
      rc=$(rc_of "$1")
      if [ "$rc" -ne 0 ] && grep -q "command not allowed by the nixtache deploy gate" "$TMPDIR/g.err"; then
        echo "ok: rejected: $1"
      else
        echo "FAIL: variant NOT rejected: $1 (rc=$rc)"; cat "$TMPDIR/g.out" "$TMPDIR/g.err"; fails=1
      fi
    }

    reject "df --output=avail -B1 /nix/store"
    reject "df -B1 --output=avail /nix/store/"
    reject "df -h /nix/store"
    reject "df -B1 --output=avail /nix/store; id"
    reject "df -B1 --output=avail /nix/store && id"
    reject "df -B1 --output=avail /nix/store > /tmp/x"

    [ -z "$fails" ] || exit 1
    echo "ssh-gate df: all scenarios passed" > "$out"
  '';
in
pkgs.runCommand "deploy-target-module-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    # Behavioral sub-suites (build dependencies — a failure there fails this
    # build before the report is even printed).
    cat ${applyGuardTest} ${gateTest}
    cp "$reportPath" "$out"
    cat ${applyGuardTest} ${gateTest} >> "$out"
    if [ -s "$failMsgPath" ]; then
      echo
      cat "$failMsgPath"
      printf '\n%s\n' "$(<$failMsgPath)" >> "$out"
      exit 1
    fi
  ''

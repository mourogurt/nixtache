# Pure-evaluation tests for the overlay-nix module
# (`services.nixtache.overlay-nix`).
#
# Pins the option-level contract without booting a VM: the upperOnUpdate
# policy is a two-value enum with default "wipe", and the cutover lifecycle
# unit's ordering follows the selected policy. Runtime behaviour across swaps
# is covered by the VM suites (overlay-nix-ota-invalid-vm and variants).
#
# Exposed via the flake as `checks.<system>.overlay-nix`.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    nixpkgs.hostPlatform = system;
    services.nixtache.overlay-nix.enable = true;
  };

  mkHost = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.overlay-nix
        baseModule
        extra
      ];
    };

  cfgOf = host: host.config.services.nixtache.overlay-nix;
  servicesOf = host: host.config.systemd.services;

  # --- scenario 1: default policy is "wipe" -----------------------------------
  hostDefault = mkHost { };
  svcDefault = servicesOf hostDefault;
  scenarioDefault = {
    name = "upperOnUpdate unset: default \"wipe\" lifecycle runs before the lower-DB loader";
    checks = {
      defaultIsWipe = (cfgOf hostDefault).upperOnUpdate == "wipe";
      lifecycleExists = svcDefault ? nixtache-overlay-lifecycle;
      lifecycleSaysWipe = svcDefault ? nixtache-overlay-lifecycle
        && lib.hasInfix "wipe the upper layer" svcDefault.nixtache-overlay-lifecycle.description;
      lifecycleBeforeLowerDb = svcDefault ? nixtache-overlay-lifecycle
        && builtins.elem "nixtache-lower-store-db-load.service" svcDefault.nixtache-overlay-lifecycle.before;
      noPreupdateUnit = !(svcDefault ? nixtache-overlay-preupdate);
      noLegacyReconcileUnit = !(svcDefault ? nixtache-overlay-reconcile);
    };
  };

  # --- scenario 2: explicit "reconcile" ---------------------------------------
  hostReconcile = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "reconcile"; };
  svcReconcile = servicesOf hostReconcile;
  scenarioReconcile = {
    name = "upperOnUpdate = \"reconcile\": lifecycle follows the lower-DB loader and requires the mount";
    checks = {
      valueIsReconcile = (cfgOf hostReconcile).upperOnUpdate == "reconcile";
      lifecycleSaysReconcile = svcReconcile ? nixtache-overlay-lifecycle
        && lib.hasInfix "reconcile the upper layer" svcReconcile.nixtache-overlay-lifecycle.description;
      lifecycleAfterLowerDb = svcReconcile ? nixtache-overlay-lifecycle
        && builtins.elem "nixtache-lower-store-db-load.service" svcReconcile.nixtache-overlay-lifecycle.after;
      lifecycleAfterMount = svcReconcile ? nixtache-overlay-lifecycle
        && builtins.elem "nix-daemon-overlay-mount.service" svcReconcile.nixtache-overlay-lifecycle.after;
      lifecycleRequiresMount = svcReconcile ? nixtache-overlay-lifecycle
        && builtins.elem "nix-daemon-overlay-mount.service" svcReconcile.nixtache-overlay-lifecycle.requires;
      noPreupdateUnit = !(svcReconcile ? nixtache-overlay-preupdate);
    };
  };

  # --- scenario 3: explicit "wipe" --------------------------------------------
  hostWipe = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "wipe"; };
  scenarioWipe = {
    name = "upperOnUpdate = \"wipe\" explicit: lifecycle configured without legacy units";
    checks = {
      valueIsWipe = (cfgOf hostWipe).upperOnUpdate == "wipe";
      lifecycleExists = (servicesOf hostWipe) ? nixtache-overlay-lifecycle;
      noLegacyReconcileUnit = !((servicesOf hostWipe) ? nixtache-overlay-reconcile);
    };
  };

  # --- scenario 4: the removed "none" value fails evaluation -------------------
  # types.enum rejects the value at option-evaluation time; tryEval catches the
  # throw. The enum error text names the valid values (a nixpkgs type-property,
  # not pinnable from pure eval beyond the rejection itself).
  hostNone = mkHost { services.nixtache.overlay-nix.upperOnUpdate = "none"; };
  tryNone = builtins.tryEval (builtins.deepSeq (cfgOf hostNone).upperOnUpdate (cfgOf hostNone).upperOnUpdate);
  scenarioNoneRejected = {
    name = "upperOnUpdate = \"none\" (removed value): evaluation fails";
    checks = {
      noneRejected = !tryNone.success;
    };
  };

  # --- scenario 5: runtime daemon config carries the CA feature ---------------
  # The fleet's closure is content-addressed — runtime evaluation (e.g.
  # profile installs) must be able to evaluate CA derivations, and the daemon
  # ignores client-side feature overrides, so the feature lives in the
  # appliance's system nix.conf (nix.settings).
  scenarioCaFeature = {
    name = "daemon config: ca-derivations enabled for the content-addressed fleet closure";
    checks = {
      caFeatureOn = builtins.elem "ca-derivations"
        hostDefault.config.nix.settings.extra-experimental-features;
    };
  };

  scenarios = [
    scenarioDefault
    scenarioReconcile
    scenarioWipe
    scenarioNoneRejected
    scenarioCaFeature
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
pkgs.runCommand "overlay-nix-module-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

# Pure-evaluation tests for the ab-image module (`nixosModules.ab-image`).
#
# Fast (no KVM/QEMU): each scenario imports the module and asserts on the
# generated config — partition sizing (fixed vs "max disk"), signature
# verification (Transfer.Verify driven by publicKey), and that the A/B slots stay
# fixed-equal in both modes. The real boot behaviour is covered by ab-vm.nix.
#
# Exposed via the flake as `checks.<system>.ab-image`.
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
  };

  mkHost = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.ab-image
        baseModule
        extra
      ];
    };

  parts = host: host.config.image.repart.partitions;
  transfers = host: host.config.systemd.sysupdate.transfers;

  # --- scenario 1: FIXED mode (default, diskSize=null) -------------------------
  hostFixed = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      imageVersion = "1";
      storeSize = "2G";
      rootSize = "5G";
    };
  };
  pf = parts hostFixed;
  scenarioFixed = {
    name = "fixed mode (diskSize=null): all partitions pinned, slots equal, imageSize=auto, Verify=no";
    checks = {
      imageSizeAuto = hostFixed.config.image.repart.imageSize == "auto";
      slotFixed = pf.nix-store.repartConfig.SizeMinBytes or null == "2G" && pf.nix-store.repartConfig.SizeMaxBytes or null == "2G";
      slotBEqual = pf.empty.repartConfig.SizeMinBytes or null == pf.nix-store.repartConfig.SizeMinBytes or null;
      rootFixed = pf.root.repartConfig.SizeMinBytes or null == "5G" && pf.root.repartConfig.SizeMaxBytes or null == "5G";
      rootNoWeight = !(pf.root.repartConfig ? Weight);
      verifyNo = (transfers hostFixed)."10-nix-store".Transfer.Verify == "no";
      verifyNoBoot = (transfers hostFixed)."20-boot-image".Transfer.Verify == "no";
    };
  };

  # --- scenario 2: MAX-DISK mode (diskSize set) --------------------------------
  hostMax = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      imageVersion = "1";
      diskSize = "20G";
    };
  };
  pm = parts hostMax;
  scenarioMaxDisk = {
    name = "max-disk mode (diskSize=\"20G\"): imageSize=20G, root grows (Weight, no Max), slots STILL fixed";
    checks = {
      imageSize20 = hostMax.config.image.repart.imageSize == "20G";
      rootWeight = pm.root.repartConfig.Weight or null == 1000;
      rootNoMax = !(pm.root.repartConfig ? SizeMaxBytes);
      rootMinFloor = pm.root.repartConfig.SizeMinBytes or null == "5G";
      slotsStillFixed = pm.nix-store.repartConfig.SizeMinBytes or null == "2G" && pm.nix-store.repartConfig.SizeMaxBytes or null == "2G";
      slotBStillEqual = pm.empty.repartConfig.SizeMinBytes or null == pm.nix-store.repartConfig.SizeMinBytes or null;
    };
  };

  # --- scenario 3: publicKey ⇒ Verify=yes on every transfer --------------------
  hostSigned = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      publicKey = ''
        -----BEGIN PGP PUBLIC KEY BLOCK-----
        dummy
        -----END PGP PUBLIC KEY BLOCK-----'';
    };
  };
  scenarioSigned = {
    name = "publicKey set ⇒ Transfer.Verify=yes on both transfers + import-pubring shipped";
    checks = {
      verifyYesStore = (transfers hostSigned)."10-nix-store".Transfer.Verify == "yes";
      verifyYesBoot = (transfers hostSigned)."20-boot-image".Transfer.Verify == "yes";
      pubringShipped = hostSigned.config.environment.etc ? "systemd/import-pubring.pgp";
    };
  };

  # --- scenario 4: imageVersionFile — runtime version contract with CI --------
  # The deploy action writes the computed version into the repo file before
  # `nix build`; the module default reads it. No file → fallback "0".
  versionFile = pkgs.writeText "image-version" "20260809120000\n";
  hostVersionFile = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      imageVersionFile = versionFile;
    };
  };
  hostNoVersion = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
    };
  };
  scenarioVersionFile = {
    name = "imageVersionFile: version from repo file (CI runtime assignment); no file → \"0\"";
    checks = {
      versionFromFile = hostVersionFile.config.services.nixtache.ab-image.imageVersion == "20260809120000";
      systemImageVersion = hostVersionFile.config.system.image.version == "20260809120000";
      partitionLabel = hostVersionFile.config.image.repart.partitions.nix-store.repartConfig.Label == "nix-store_20260809120000";
      defaultIsZero = hostNoVersion.config.services.nixtache.ab-image.imageVersion == "0";
    };
  };

  scenarios = [
    scenarioFixed
    scenarioMaxDisk
    scenarioSigned
    scenarioVersionFile
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
pkgs.runCommand "ab-image-module-test"
  {
    inherit report failMsg;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

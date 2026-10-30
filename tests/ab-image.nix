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
  appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; },
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  baseModule = { lib, ... }: {
    system.stateVersion = lib.trivial.release;
    # The shipped-DB pins force `system.build.toplevel` evaluation, which runs
    # the image-based-appliance profile's lockout assertion — these hosts never
    # configure a password, so opt out the way the profile documents.
    users.allowNoPasswordLogin = true;
  };

  # The shipped DB is the closure's registered records — content-true only
  # under content-addressing. Included in every positive-leg host; the
  # negative-leg host below pins the module's assertion by simply not
  # including this module (its world then evaluates input-addressed).
  caModule = {
    nixpkgs.pkgs = appliancePkgs;
  };

  mkHost = extra:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.ab-image
        baseModule
        caModule
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

  hostPercent = mkHost {
    services.nixtache.ab-image = {
      enable = true;
      imageId = "h";
      imageVersion = "1";
      storeSize = "25%";
    };
  };
  scenarioAbsoluteStoreSize = {
    name = "storeSize: absolute values flow to both slots; percentages fail evaluation with an actionable message";
    checks = {
      absoluteAccepted = hostFixed.config.services.nixtache.ab-image.storeSize == "2G"
        && pf.nix-store.repartConfig.SizeMinBytes == "2G"
        && pf.empty.repartConfig.SizeMinBytes == "2G";
      percentageRefused = !(builtins.tryEval hostPercent.config.system.build.toplevel.outPath).success;
      actionableMessage = builtins.any
        (a: !a.assertion
          && lib.hasInfix "ab-image.storeSize" a.message
          && lib.hasInfix "absolute" a.message
          && lib.hasInfix "capacity plan" a.message)
        hostPercent.config.assertions;
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

  # --- scenario 3: publicKey => Verify=yes on every transfer --------------------
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
    name = "publicKey set => Transfer.Verify=yes on both transfers + import-pubring shipped";
    checks = {
      verifyYesStore = (transfers hostSigned)."10-nix-store".Transfer.Verify == "yes";
      verifyYesBoot = (transfers hostSigned)."20-boot-image".Transfer.Verify == "yes";
      pubringShipped = hostSigned.config.environment.etc ? "systemd/import-pubring.pgp";
    };
  };

  # --- scenario 4: imageVersionFile — runtime version contract with CI --------
  # The deploy action writes the computed version into the repo file before
  # `nix build`; the module default reads it. No file → fallback "0".
  # builtins.toFile, not pkgs.writeText: imageVersionFile is read at eval time
  # (IFD in the module's imageVersion default) — a derivation here makes every
  # foreign-system flake check demand a build it cannot run.
  versionFile = builtins.toFile "image-version" "20260809120000\n";
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

  # --- scenario 5: shipped lower store DB ------------------------------------
  # The dump MUST be produced by the module's dump generator for THIS host's
  # toplevel: rebuilding the derivation here pins both that the dump exists
  # and that its records cover exactly the running toplevel's closure (the
  # closure's REGISTERED records — content-true because the fixture
  # evaluates content-addressed). The store content itself ships via the
  # store tree (one CopyFiles source — see scenario 6): top-level symlink
  # closure paths image as symlinks, so the records match the shipped bytes
  # for any closure composition. The dump ships on the ESP at a versioned
  # path and rides updates via the 15-lower-db transfer — it cannot live in
  # /etc (derivation cycle: the dump covers the toplevel) nor inside
  # /nix/store (overlay GC hard-fails on non-store-path entries in the
  # merged store dir).
  #
  # Rebuilt with the FIXTURE's pkgs (hostFixed.pkgs): under CA every
  # derivation outPath depends on the pkgs instance's config, so the identity
  # pin must use the same instance the module evaluated with.
  expectedDump = import ../modules/ab-image/lower-store-db.nix {
    pkgs = hostFixed.pkgs;
    toplevel = hostFixed.config.system.build.toplevel;
  };
  expectedTree = import ../modules/ab-image/store-tree.nix {
    pkgs = hostFixed.pkgs;
    toplevel = hostFixed.config.system.build.toplevel;
  };
  # Negative leg: a non-CA evaluation must fail the module's assertion
  # (built without caModule — see the first-definition-wins note there).
  hostNonCa = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.ab-image
      baseModule
      {
        services.nixtache.ab-image = {
          enable = true;
          imageId = "h";
          imageVersion = "1";
        };
      }
    ];
  };
  espContents = hostFixed.config.image.repart.partitions.esp.contents;
  dumpContent = espContents."/EFI/nixtache/h_1.lower-db" or null;
  lowerDbTransfer = (transfers hostFixed)."15-lower-db" or null;
  lowerDbSvc = hostFixed.config.systemd.services.nixtache-lower-store-db-load or null;
  versionedSvc = hostVersionFile.config.systemd.services.nixtache-lower-store-db-load or null;
  scenarioLowerStoreDb = {
    name = "lower store DB: registered-record dump ships on the ESP + rides sysupdate; boot loader seeds a missing/stale DB; CA asserted";
    checks = {
      caFixture = hostFixed.pkgs.config.contentAddressedByDefault or false;
      nonCaRejected = builtins.any
        (a: !a.assertion && lib.hasInfix "content-addressed" a.message)
        hostNonCa.config.assertions;
      dumpShipped = dumpContent != null;
      dumpIsToplevelClosure = dumpContent != null && toString dumpContent.source == toString expectedDump;
      dumpIsRegistration = dumpContent != null && lib.hasInfix "registration" (expectedDump.passthru.checkScript or "");
      storeTreeIsCopySource = dumpContent != null
        && (pf.nix-store.repartConfig.CopyFiles or null) == [ "${toString expectedTree}:/" ];
      storePathsAbandoned = (pf.nix-store.storePaths or [ ]) == [ ];
      dumpTransferExists = lowerDbTransfer != null;
      dumpTransferPattern = lowerDbTransfer != null
        && (lowerDbTransfer.Source.MatchPattern or [ ]) == [ "h_@v.lower-db" ]
        && (lowerDbTransfer.Target.InstancesMax or null) == 2;
      linksShipped = hostFixed.config.image.repart.partitions.nix-store.contents ? "/.links/.keep";
      nixCliShipped = builtins.elem hostFixed.pkgs.nix hostFixed.config.environment.systemPackages;
      loaderExists = lowerDbSvc != null;
      loaderWanted = lowerDbSvc != null && builtins.elem "multi-user.target" lowerDbSvc.wantedBy;
      loaderBeforeDaemon = lowerDbSvc != null && builtins.elem "nix-daemon.service" lowerDbSvc.before;
      loaderReadsDump = lowerDbSvc != null && lib.hasInfix "/boot/EFI/nixtache/h_1.lower-db" lowerDbSvc.script;
      loaderTracksMarker = lowerDbSvc != null && lib.hasInfix "/var/lib/nixtache/lower-db-version" lowerDbSvc.script;
      loaderBakesVersion = versionedSvc != null && lib.hasInfix "/boot/EFI/nixtache/h_20260809120000.lower-db" versionedSvc.script;
    };
  };

  scenarios = [
    scenarioFixed
    scenarioAbsoluteStoreSize
    scenarioMaxDisk
    scenarioSigned
    scenarioVersionFile
    scenarioLowerStoreDb
    scenarioStoreTreeFaithful
  ];

  # --- scenario 6: faithful store imaging (store tree) ----------------------
  # The image builder (systemd-repart) dereferences each CopyFiles source it
  # is handed, so the store partition must receive ONE source — the staging
  # tree — whose per-path entries are materialised with top-level symlink
  # paths recreated as symlinks. The build-level half below builds the tree
  # for a tiny closure that CONTAINS a top-level symlink path and asserts
  # the symlink and its target survive staging (a mangled tree would fail
  # this derivation, failing the check); the boot-level half lives in the
  # overlay-nix VM suites (symlink path ships, path-info resolves it).
  symlinkFixturePath = pkgs.runCommand "symlink-fixture" { }
    "ln -s ${pkgs.hello} $out";
  storeTreeSymlinkCheck = pkgs.runCommand "store-tree-symlink-check"
    { tree = import ../modules/ab-image/store-tree.nix {
        inherit pkgs;
        toplevel = symlinkFixturePath;
      };
    }
    ''
      set -euo pipefail
      link=""
      for p in "$tree"/*; do
        case "$p" in *-symlink-fixture) link="$p";; esac
      done
      [ -n "$link" ] || { echo "symlink fixture path missing from the staged tree" >&2; exit 1; }
      [ -L "$link" ] || { echo "staged entry is not a symlink: $link" >&2; exit 1; }
      target=$(readlink "$link")
      [ "$target" = "${pkgs.hello}" ] || { echo "symlink target mangled: $target" >&2; exit 1; }
      [ -x "$tree/$(basename "${pkgs.hello}")/bin/hello" ] \
        || { echo "closure content missing from the staged tree" >&2; exit 1; }
      touch "$out"
    '';
  scenarioStoreTreeFaithful = {
    name = "store imaging: store tree preserves top-level symlink closure paths";
    checks = {
      symlinkCheckIsBuild = lib.isDerivation storeTreeSymlinkCheck;
      espPinned = pf.esp.repartConfig.SizeMinBytes or null == "260M"
        && pf.esp.repartConfig.SizeMaxBytes or null == "260M";
      espPinnedMaxDisk = pm.esp.repartConfig.SizeMinBytes or null == "260M"
        && pm.esp.repartConfig.SizeMaxBytes or null == "260M";
    };
  };

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
    # Builds the store-tree symlink check as part of this check output —
    # a tree that mangles top-level symlink paths fails the whole suite.
    inherit storeTreeSymlinkCheck;
    passAsFile = [ "report" "failMsg" ];
  }
  ''
    cat "$reportPath"
    cp "$reportPath" "$out"
    if [ -s "$failMsgPath" ]; then echo; cat "$failMsgPath"; printf '\n%s\n' "$(<$failMsgPath)" >> "$out"; exit 1; fi
  ''

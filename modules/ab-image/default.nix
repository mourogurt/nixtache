# nixosModules.ab-image — the FULL A/B image config (Batch E), in nixtache.
#
# Generates the consumer-side A/B prep that used to be copy-pasted: repart
# A/B slots, UKI, systemd.sysupdate transfers, system.image.{id,version},
# boot-counting, AND signature verification (import-pubring.pgp + Transfer.Verify).
# Consumers import this ONLY for A/B targets (alongside nixosModules.deploy-target
# for the runtime side: polkit/gating). Every field is an mkOption with a default
# and overridable — advanced consumers can swap the layout via `extraPartitions`
# / `transfers` while trivial consumers set just `imageId` + `publicKeyFile`.
#
# WHY a separate module (not folded into deploy-target.ab): this imports nixpkgs'
# `image-based-appliance` profile, which forces `nix.enable=false` +
# `system.switch.enable=false` (appliances have no Nix, can't be rebuilt). That
# would break live (desktop/laptop) targets that also import deploy-target. So
# the aggressive image profile lives HERE, imported only by A/B targets.
#
# Signing model (Q2): the runner host signs with the PRIVATE key
# (`services.nixtache.runner.deploy.ab.signingKeyFile`); each target sets the
# matching PUBLIC key here (`publicKeyFile`/`publicKey`) → this module installs
# /etc/systemd/import-pubring.pgp and forces `Transfer.Verify=yes` so sysupdate
# rejects unsigned/tampered manifests. systemd-sysupdate verifies ONLY OpenPGP.
#
# Design details: doc/archive/specs/direct-deploy/06-ab-image.md.
{ config, lib, pkgs, modulesPath, ... }:

with lib;

let
  cfg = config.services.nixtache.ab-image;
  # True when the target is configured to verify staged manifests (a public key
  # is provided). Drives Transfer.Verify on every sysupdate transfer.
  verify = cfg.publicKeyFile != null || cfg.publicKey != null;

  # Remote (HTTP/HTTPS) vs local-self staging source. stagingPath may be a
  # local dir ("/run/abtest-stage") or a URL ("http://host:8000"); the
  # sysupdate Source Type differs (regular-file vs url-file). Local sources
  # use the plain absolute path — sysupdate rejects file:// URIs for
  # regular-file sources ("not a normalized, absolute path").
  isUrl = hasPrefix "http" cfg.stagingPath;
  srcPath = "${cfg.stagingPath}/";
  srcType = if isUrl then "url-file" else "regular-file";

  # The pubring shipped to /etc/systemd/import-pubring.pgp. Accept either a path
  # to a key file or an ASCII-armored key string (dearmored at build time).
  pubringSource =
    if cfg.publicKeyFile != null then cfg.publicKeyFile
    else if cfg.publicKey != null then
      pkgs.runCommand "import-pubring.pgp" { nativeBuildInputs = [ pkgs.gnupg ]; }
        '' gpg --dearmor < ${pkgs.writeText "pubkey.asc" cfg.publicKey} > $out ''
    else null;

  efiArch = pkgs.stdenv.hostPlatform.efiArch;

  # Default sysupdate transfers. `@v` carries the version; Path is STATIC
  # (sysupdate.d(5)). Local-self uses a plain-path regular-file source; a
  # remote target uses http(s):// + url-file (set stagingPath to the URL).
  # Verify is forced from publicKey/publicKeyFile on every transfer.
  defaultTransfers = {
    "10-nix-store" = {
      Source = {
        Path = srcPath;
        Type = srcType;
        MatchPattern = [ "${cfg.imageId}_@v.nix-store.raw" ];
      };
      Target = {
        InstancesMax = 2;
        Path = "auto";
        MatchPattern = "nix-store_@v";
        Type = "partition";
        MatchPartitionType = "linux-generic";
        ReadOnly = "yes";
      };
      Transfer.Verify = if verify then "yes" else "no";
    };
    "20-boot-image" = {
      Source = {
        Path = srcPath;
        Type = srcType;
        MatchPattern = [ "${cfg.imageId}_@v.efi" ];
      };
      Target = {
        InstancesMax = 2;
        MatchPattern = [ "${cfg.imageId}_@v.efi" ];
        Mode = "0444";
        Path = "/EFI/Linux";
        PathRelativeTo = "boot";
        Type = "regular-file";
      };
      Transfer.Verify = if verify then "yes" else "no";
    };
  };
in
{
  # image.repart + the appliance profile are NOT in the default import list.
  # This module is imported only by A/B targets, so the aggressive profile is OK.
  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/image-based-appliance.nix"
  ];

  options.services.nixtache.ab-image = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Generate the full A/B image config on this target: repart A/B slots +
        UKI + systemd.sysupdate transfers + system.image.{id,version} +
        boot-counting + (when a public key is set) signature verification.
        Import this module ONLY on A/B targets — it pulls the image-based-appliance
        profile (nix.enable=false), which is wrong for live-rebuilt machines.
        Pair with services.nixtache.deploy-target.ab (runtime: polkit/gating).
      '';
    };

    imageId = mkOption {
      type = types.str;
      example = "server";
      description = ''
        Stable image identifier (system.image.id). Used in image filenames
        (`<id>_<version>.{raw,efi}`), the UKI name, and the sysupdate MatchPattern.
        Must not change across updates of the same machine.
      '';
    };

    imageVersion = mkOption {
      type = types.str;
      # Runtime versioning: the version is assigned by CI at build time, not
      # hardcoded in the config. The deploy action writes the computed version
      # (calver) into the repo's `image-version` file right before
      # `nix build`; this default picks it up via `imageVersionFile`.
      default =
        if cfg.imageVersionFile != null
        then lib.strings.trim (builtins.readFile cfg.imageVersionFile)
        else "0";
      defaultText = literalMD ''
        contents of `imageVersionFile` when set, otherwise `"0"`.
      '';
      description = ''
        Image version (system.image.version). Must be a comparable value for
        systemd-sysupdate's @v (an integer, or dotted). MUST change per update
        or sysupdate sees nothing new. Production: point `imageVersionFile` at
        the repo's version file and let CI assign the value at build time
        (the deploy action writes a UTC calver before `nix build`). An
        explicit string here is for tests/one-off bootstrap images.
      '';
    };

    imageVersionFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./image-version";
      description = ''
        Repo file the image version is read from at evaluation time. Contract
        with the deploy action: the consumer commits this file (content `0`),
        CI overwrites it with the computed version right before `nix build`
        (and `git add -f`s it — flakes read the git index). This keeps the
        flake pure while the version itself is assigned at CI runtime, so
        os-release / UKI name / staged filenames / GPT label all carry the
        SAME runtime version. `null` = no file; `imageVersion` is used as-is.
      '';
    };

    stagingPath = mkOption {
      type = types.str;
      default = "/run/abtest-stage";
      description = ''
        sysupdate Source Path: where the target reads staged images from.
        Default is a local-self dir (regular-file source) the deploy script
        populates. For a
        REMOTE target (pulling from the runner host over HTTPS), override to
        `https://<runner-host>/ab-stage/<cfg>/` (and the deployer serves it).
      '';
    };

    storeSize = mkOption {
      type = types.str;
      # Single source of truth is the runtime side: when the deploy-target
      # partitions module is co-imported and enabled, its slotSize is
      # inherited (ab-provision's A2 assert still guards explicit mismatches).
      default =
        if config.services.nixtache.deploy-target.ab.partitions.enable or false
        then config.services.nixtache.deploy-target.ab.partitions.slotSize
        else "2G";
      defaultText = literalMD ''
        `services.nixtache.deploy-target.ab.partitions.slotSize` when that
        module is co-imported and enabled, otherwise `"2G"`.
      '';
      description = ''
        nix-store slot size. Slot A and the reserved slot B are each this big.
        Accepts absolute sizes ("2G", "512M") or percentages ("10%").
        Percentages are resolved at runtime by the provision module against
        the target disk size; repart (build-time) needs absolute — if a
        percentage is passed, it defaults to "2G" for the image build.
      '';
    };

    storeFs = mkOption {
      type = types.enum [ "squashfs" "erofs" ];
      default = "squashfs";
      description = ''
        Filesystem format for the nix-store A/B partitions. Both are
        read-only compressed formats — the store is immutable (nix.enable
        = false on appliances).

        `squashfs` (default): mature, widely supported. Compressors: gzip,
        lzo, lz4, xz, zstd, lzma.

        `erofs`: modern, per-inode compression (different files can use
        different algorithms), used by nixpkgs' own verity-protected
        appliance images. Compressors: lz4, lz4hc, lzma, deflate,
        libdeflate, zstd.

        Compression is BUILD-TIME ONLY for both — the algorithm is baked
        into the image. See `storeCompression` / `storeCompressionLevel`.
      '';
    };

    storeCompression = mkOption {
      type = types.nullOr types.str;
      default = "zstd";
      description = ''
        Compression algorithm for the nix-store image. Passed to repart as
        `Compression=` (systemd ≥257), which dispatches to the correct
        mkfs flag:
        - squashfs → `mksquashfs -comp <algo>`
        - erofs    → `mkfs.erofs -z<algo>`
        Set to null to use each tool's default (gzip for squashfs, lz4 for
        erofs).
      '';
    };

    storeCompressionLevel = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 19;
      description = ''
        Numeric compression level (FS-specific meaning). Passed to repart as
        `CompressionLevel=`. Only honored when `storeCompression` is non-null.
        Typical ranges: zstd 1–22 (19 = high), xz 0–9, lz4 1–12.
        null = tool default.
      '';
    };

    rootSize = mkOption {
      type = types.str;
      default = "5G";
      description = ''
        Persistent root partition (ext4) size: /etc, /var, and state that survives updates.
        When `diskSize` is set, this becomes the MINIMUM (root grows via Weight to
        fill `diskSize`); otherwise it is the fixed size.
      '';
    };

    diskSize = mkOption {
      type = types.nullOr (types.strMatching "^([0-9]+[KMGTP]?|auto)$");
      default = null;
      example = "20G";
      description = ''
        "Max disk" sizing mode: total image size (K/M/G/T). When set, the image is
        built at this size and the root partition grows (Weight, SizeMinBytes=
        `rootSize` floor, no SizeMax) to fill the space left by the fixed A/B
        slots + ESP. When null (default), every partition is fixed
        (SizeMinBytes = SizeMaxBytes) — the appliance is a minimal image of exactly
        the sum of its partitions (the nixcademy pattern). The A/B nix-store slots
        are ALWAYS fixed-equal regardless (they must hold the same squashfs image).
        Note: repart SizeMin/Max take only bytes+KMG (no `%`); proportional fill is
        via Weight (see repart.d(5)).
      '';
    };

    ukiTries = mkOption {
      type = types.ints.positive;
      default = 3;
      description = "Boot attempts the UKI carries (Automatic Boot Assessment). Reaching boot-complete.target blesses; exhausting tries rolls back.";
    };

    publicKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the OpenPGP PUBLIC key (binary or ASCII-armored) matching the
        runner host's signing key. When set, the module installs
        /etc/systemd/import-pubring.pgp and forces Transfer.Verify=yes — sysupdate
        then rejects staged manifests whose SHA256SUMS.gpg doesn't verify.
        Mutually exclusive with publicKey (one suffices). null = no verification.
      '';
    };

    publicKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ASCII-armored OpenPGP PUBLIC key string (alternative to publicKeyFile —
        convenient when the public key is committed in-repo). Decompiled to a
        binary keyring at build time.
      '';
    };

    extraPartitions = mkOption {
      type = types.attrsOf (types.submodule {
        options.repartConfig = mkOption {
          type = types.attrs;
          description = "systemd-repart repartConfig for this extra partition (Type, Label, Format, SizeMinBytes, …).";
        };
      });
      default = { };
      description = ''
        Extra repart partitions to merge into the image (e.g. a persistent data
        partition for the mount-preservation test). The A/B system update swaps
        only the nix-store slot — these are never touched.
      '';
    };

    transfers = mkOption {
      # INI atoms as systemd.sysupdate.transfers accepts them: str | int | bool |
      # listOf str (per leaf). Loose on purpose — forwarded to sysupdate, which
      # validates the final shape.
      type = with types; attrsOf (attrsOf (attrsOf (either str (either int (either bool (listOf str))))));
      default = defaultTransfers;
      defaultText = literalMD "the local-path nix-store + UKI transfers (see source)";
      description = ''
        systemd.sysupdate transfers (override the defaults, e.g. to switch a
        remote target to `https://` Source). Verify on each is forced from
        publicKey/publicKeyFile.
      '';
    };
  };

  config = mkIf cfg.enable {
    system.image.id = cfg.imageId;
    system.image.version = cfg.imageVersion;

    # UKI boot model (the appliance profile enables bootspec/UKI); no grub.
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.bootCounting.enable = true;
    boot.uki.name = cfg.imageId;
    boot.uki.tries = cfg.ukiTries;
    # Headless-friendly: route kernel + getty to the serial port so QEMU -serial
    # sees boot output. Plain assignment (NOT mkDefault) so it isn't silently
    # dropped by an empty higher-priority definition — the console is mandatory
    # for the test driver. A consumer appending more params still merges (list).
    boot.kernelParams = [ "console=ttyS0" ];

    # Mount the A/B partitions by GPT partlabel. Extra partitions in
    # extraPartitions are not auto-mounted (consumer wires fileSystems if needed).
    fileSystems = let
      cfgForLabel = label: let
        inherit (config.image.repart.partitions.${label}) repartConfig;
      in {
        device = "/dev/disk/by-partlabel/${repartConfig.Label}";
        fsType = repartConfig.Format;
      };
    in {
      "/" = cfgForLabel "root";
      "/boot" = cfgForLabel "esp";
      "/nix/store" = cfgForLabel "nix-store";
    };

    image.repart = {
      name = cfg.imageId;
      split = true;
      # "max disk" mode: build the image at a fixed total size; root then fills
      # (Weight) what the fixed slots + ESP leave. null (default) = minimal image.
      imageSize = mkIf (cfg.diskSize != null) cfg.diskSize;
      # EROFS density: block-aligned file tails waste ~half a block per file
      # (≈40M on a ~22K-file closure), which makes erofs lose to squashfs
      # despite zstd. fragments/ztailpacking pack the tails; -C1M (big_pcluster)
      # lets zstd compress across 4K block boundaries. No-ops when the store is
      # uncompressed. Repart appends these after the positional args (getopt
      # permutes) via SYSTEMD_REPART_MKFS_OPTIONS_EROFS.
      mkfsOptions = mkIf (cfg.storeFs == "erofs") {
        erofs = [ "-Efragments,ztailpacking" "-C1048576" ];
      };
      partitions = cfg.extraPartitions // {
        esp = {
          contents = {
            "/EFI/BOOT/BOOT${toUpper efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
            "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
              timeout 3
            '';
          };
          repartConfig = {
            Type = "esp"; Label = "boot"; Format = "vfat";
            SizeMinBytes = "200M"; SplitName = "-";
          };
        };
        nix-store = {
          storePaths = [ config.system.build.toplevel ];
          nixStorePrefix = "/";
          repartConfig = mkMerge [
            {
              Type = "linux-generic"; Label = "nix-store_${cfg.imageVersion}";
              # Minimize=on: the partition image shrinks to fit the compressed
              # squashfs/erofs content (needed for the compression size comparison
              # in ab-compression-vm). The A/B SLOT sizes on the target disk are
              # fixed by the provision module, not by this build-time partition.
              Minimize = "on";
              # Percentages → fallback for build-time (provision resolves at runtime).
              SizeMinBytes = if (hasSuffix "%" cfg.storeSize) then "2G" else cfg.storeSize;
              SizeMaxBytes = if (hasSuffix "%" cfg.storeSize) then "2G" else cfg.storeSize;
              Format = cfg.storeFs; ReadOnly = "yes"; SplitName = "nix-store";
            }
            # Compression keys (systemd ≥257): same key names for squashfs and erofs,
            # repart dispatches to the correct mkfs flag internally.
            (optionalAttrs (cfg.storeCompression != null) {
              Compression = cfg.storeCompression;
            })
            (optionalAttrs (cfg.storeCompressionLevel != null) {
              CompressionLevel = cfg.storeCompressionLevel;
            })
          ];
        };
        # Reserved space for slot B — empty until the first sysupdate fills it.
        # Must match nix-store partition size (same slotSize).
        empty.repartConfig = {
          Type = "linux-generic"; Label = "_empty"; Minimize = "off";
          SizeMinBytes = if (hasSuffix "%" cfg.storeSize) then "2G" else cfg.storeSize;
          SizeMaxBytes = if (hasSuffix "%" cfg.storeSize) then "2G" else cfg.storeSize;
          SplitName = "-";
        };
        root.repartConfig = mkMerge [
          {
            Type = "root"; Format = "ext4"; Label = "root"; Minimize = "off";
            SizeMinBytes = cfg.rootSize; SplitName = "-";
          }
          # fixed mode (default): pin root to rootSize. max-disk mode (diskSize
          # set): drop SizeMax + give Weight so root fills diskSize minus the
          # fixed slots/ESP.
          (if cfg.diskSize == null then { SizeMaxBytes = cfg.rootSize; } else { Weight = 1000; })
        ];
      };
    };

    systemd.sysupdate.enable = true;
    # Signature verification spawns `gpg2` from the service's PATH. nixpkgs
    # only equips the D-Bus `systemd-sysupdated` with gnupg — the plain
    # `systemd-sysupdate.service` oneshot (what the deploy action triggers via
    # SSH) has an empty PATH otherwise and every Verify=yes pull fails with a
    # broken verifier pipe. (Same wiring as deploy-target's ab-provision; the
    # list option merges if both are active.)
    systemd.services.systemd-sysupdate = mkIf verify {
      path = [ pkgs.gnupgMinimal ];
    };
    # mkDefault: ab-provision (deploy-target/ab.nix) overrides these when
    # partitions.enable = true, deriving transfers from slot_a/slot_b (e.g.
    # different disks → two InstancesMax=1 transfers instead of one =2).
    # Without ab-provision (standalone tests like ab-vm.nix), these defaults apply.
    systemd.sysupdate.transfers = mkDefault cfg.transfers;

    # The update artifact the deploy action stages + signs: the split nix-store
    # squashfs + the UKI + a SHA256SUMS manifest. The UKI is renamed to drop the
    # `+tries` suffix (ukify bakes boot-counting tries into the FILENAME like
    # `abtest_2+3.efi`, which breaks sysupdate's `MatchPattern abtest_@v.efi`;
    # sd-stub reads the tries from the UKI section regardless of the filename).
    system.build.sysupdate-package =
      pkgs.runCommand "sysupdate-package-${cfg.imageVersion}" { } ''
        mkdir $out
        cp ${config.system.build.uki}/${config.system.boot.loader.ukiFile} $out/${cfg.imageId}_${cfg.imageVersion}.efi
        cp ${config.system.build.image}/${cfg.imageId}_${cfg.imageVersion}.nix-store.raw $out/
        cd $out && sha256sum * > SHA256SUMS
      '';

    # Public key → verification. `optionalAttrs` so the entry is absent when no
    # key (otherwise the UKI build reads an unset source). Install at BOTH paths
    # sysupdate/gpgme discover (the /usr/lib vs /etc exclusive-override logic,
    # systemd#40702, means relying on /etc alone can fail).
    environment.etc = optionalAttrs verify {
      "systemd/import-pubring.pgp".source = pubringSource;
    };
    systemd.tmpfiles.rules = optionals verify [
      "L+ /usr/lib/systemd/import-pubring.pgp - - - - ${pubringSource}"
    ];
  };
}

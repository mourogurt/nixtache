# A/B partition provisioning — runtime slot layout for `method = "ab-image"` targets.
#
# Fills the gap between `systemd-sysupdate` (which WRITES slots but cannot CREATE
# them) and `systemd-repart` (which can GROW partitions at boot but never shrink
# or create the initial A/B layout). Owns three things:
#
#   1. `services.nixtache.deploy-target.ab.partitions.*` — declarative slot config
#      (slot_a/slot_b submodules, slotSize, autoInit, onSizeMismatch,
#      protectedLabels).
#   2. `nixtache-ab-provision.service` — idempotent oneshot that runs BEFORE
#      `systemd-sysupdate.service` at boot: detects the current GPT state
#      (normal / post-wipe / missing), migrates / size-checks / wipes as configured.
#      Only provisioned for `type = "partition"` (regular-file targets let
#      sysupdate create the backing files itself).
#   3. `systemd.sysupdate.transfers` derivation — when `partitions.enable = true`
#      this module is the SOLE owner of transfers: it sets them at normal
#      priority so they cleanly override ab-image's `mkDefault` definitions.
#      Same-disk → one `10-nix-store` transfer
#      (InstancesMax=2); different disks → `10-nix-store-a` + `10-nix-store-b`
#      (InstancesMax=1 each); regular-file → Target.Type = "regular-file".
#
# Stateless detection: the provision script
# derives the current state purely from GPT label counts, never from a state
# file. Labels follow the sysupdate-native model: a WRITTEN slot carries
# `nix-store_<v>` (version in the label), a FREE slot is `_empty` — the marker
# systemd-sysupdate hardcodes for "not used so far" (it discovers free slots
# by that exact label, writes them, and relabels to `nix-store_<v>`; vacuuming
# an old version relabels back to `_empty`). So a healthy disk always has one
# `nix-store_N` (active, chosen by the UKI cmdline) plus zero or more
# `nix-store_M`/`_empty` slots. Provision creates `nix-store_1` + `_empty`
# (the same layout the ab-image build ships) and treats both label families as
# "slot exists" — which makes `onSizeMismatch = "wipe"` idempotent: wipe
# recreates the same label pair at the new size, the next boot classifies the
# disk as Normal with matching sizes → provision no-ops.
#
# This module is loaded by `modules/deploy-target/default.nix`. It extends the
# EXISTING `services.nixtache.deploy-target.ab` attrset (declared by ab.nix) with
# a new `partitions` key — the two modules compose without conflict.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nixtache.deploy-target;
  ab = cfg.ab;
  partitions = ab.partitions;

  # Whether the ab-image module is also imported on this target. The size-match
  # assertion only fires when ab-image is present (it compares slotSize against
  # ab-image.storeSize). When ab-image is absent (standalone ab-provision, e.g.
  # the contract tests), the size check is skipped — there's no storeSize to
  # compare against. `builtins.hasAttr` is a direct attrset check on
  # `config.services.nixtache` (which always exists — deploy-target defines it),
  # so it never throws on a missing option path.
  abImagePresent = builtins.hasAttr "ab-image" config.services.nixtache;
  abImage = if abImagePresent then config.services.nixtache.ab-image else { };
  imageId = abImage.imageId or "nixtache";

  slotA = partitions.slot_a;
  slotB = partitions.slot_b;
  isPartition = slotA.type == "partition";
  isRegularFile = slotA.type == "regular-file";
  sameStorage = slotA.storage == slotB.storage;

  # Image id for the sysupdate Source MatchPattern: explicit option wins;
  # otherwise inherited from a co-imported ab-image; "nixtache" as last resort.
  imageId' = if partitions.imageId != null then partitions.imageId else imageId;

  # Pubring for Transfer.Verify — mirrors ab-image's publicKeyFile/publicKey
  # handling. When ab-image is co-imported AND has its own key, its pubring
  # install wins (the image builder's key is THE signing key); this module's
  # key options are for targets that do NOT import ab-image.
  provisionPubring = partitions.publicKeyFile != null || partitions.publicKey != null;
  abImageHasKey = (abImage.publicKeyFile or null) != null || (abImage.publicKey or null) != null;
  pubringSource =
    if partitions.publicKeyFile != null then partitions.publicKeyFile
    else if partitions.publicKey != null then
      pkgs.runCommand "import-pubring.pgp" { nativeBuildInputs = [ pkgs.gnupg ]; }
        ''gpg --dearmor < ${pkgs.writeText "pubkey.asc" partitions.publicKey} > $out''
    else null;

  # Verification is on when explicitly requested OR when a key is given
  # (same convention as ab-image: a configured key implies verification).
  verifyEffective = partitions.verify || provisionPubring;

  # OTA source: a URL (http/https → url-file) or a local directory
  # (→ regular-file with a plain absolute path — sysupdate rejects file://
  # URIs for regular-file sources: "not a normalized, absolute path").
  # null = no Source from this module (a co-imported ab-image supplies its
  # own; without ab-image a mkDefault placeholder is emitted for the
  # consumer to override).
  haveSource = partitions.source != null;
  abImageActive = abImagePresent && (abImage.enable or false);
  srcIsUrl = haveSource && hasPrefix "http" partitions.source;
  srcPath =
    if !haveSource then "/run/nixtache-stage/"
    else "${removeSuffix "/" partitions.source}/";
  srcType = if srcIsUrl then "url-file" else "regular-file";

  # Source/Verify ownership rules (ab-image ships its transfers as one big
  # mkDefault attrset — same-priority ties on a scalar leaf are eval errors):
  # - partitions.source set        → Source at NORMAL priority (sole owner)
  #   — cleanly overrides ab-image's mkDefault.
  # - source null + ab-image active → Source omitted; ab-image's survives.
  # - source null + no ab-image     → mkDefault placeholder (consumer/test
  #   overrides individual keys directly, e.g. tests do).
  # Same three-way split for Transfer.Verify (explicit verify/key wins).
  mkSource = matchPattern:
    if haveSource then {
      Source = { Path = srcPath; Type = srcType; MatchPattern = [ matchPattern ]; };
    }
    else if !abImageActive then {
      Source = mkDefault { Path = srcPath; Type = srcType; MatchPattern = [ matchPattern ]; };
    }
    else { };
  mkVerify =
    if verifyEffective then { Transfer.Verify = "yes"; }
    else if !abImageActive then { Transfer.Verify = mkDefault "no"; }
    else { };

  # sysupdate transfer derivation. ab-provision owns the Target structure
  # (slot discovery) at normal priority.
  mkStoreTransfer = storage: instances:
    mkSource "${imageId'}_@v.nix-store.raw" // {
      Target = {
        InstancesMax = instances;
        Path = storage;
        MatchPattern = if isPartition then "nix-store_@v" else "${imageId'}_@v.nix-store.raw";
        Type = slotA.type;
      } // (optionalAttrs isPartition {
        MatchPartitionType = "linux-generic";
        ReadOnly = "yes";
      });
    } // mkVerify;

  storeTransfers =
    if isRegularFile then
      { "10-nix-store" = mkStoreTransfer slotA.storage 2; }
    else if sameStorage then
      { "10-nix-store" = mkStoreTransfer slotA.storage 2; }
    else
      {
        "10-nix-store-a" = mkStoreTransfer slotA.storage 1;
        "10-nix-store-b" = mkStoreTransfer slotB.storage 1;
      };

  # UKI (.efi) transfer — derived only when ab-image is absent (on a real
  # appliance ab-image owns it). Target: "auto" = the ESP's /EFI/Linux via
  # sysupdate's $BOOT autodiscovery (mirrors ab-image); any other value is an
  # absolute directory (plain hosts / test VMs without an ESP).
  bootTransfer = optionalAttrs (!abImageActive) {
    "20-boot-image" = mkSource "${imageId'}_@v+@l.efi" // {
      Target = {
        InstancesMax = 2;
        MatchPattern = [ "${imageId'}_@v+@l.efi" ];
        Mode = "0444";
        Type = "regular-file";
      } // (if partitions.bootTarget == "auto" then {
        Path = "/EFI/Linux";
        PathRelativeTo = "boot";
      } else {
        Path = partitions.bootTarget;
      });
    } // mkVerify;
  };

  # Slot submodule: type + storage + label. Both slots share the same submodule
  # shape, parameterized only by the default GPT label (slot A conventionally
  # `nix-store_1`, slot B sysupdate's `_empty` free-slot marker); an assert
  # below enforces slot_a.type == slot_b.type (sysupdate requires a uniform
  # Target.Type across all instances of one transfer).
  slotSubmod = defaultLabel: types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "partition" "regular-file" ];
        description = ''
          How this A/B slot is backed.
          - `"partition"`: a GPT partition on a block device (production). The
            provision service creates/migrates it via `sgdisk`.
          - `"regular-file"`: a regular file under a directory (tests, loopback,
            no GPT). sysupdate creates the files itself; provision is skipped.
        '';
      };
      storage = mkOption {
        type = types.str;
        example = "/dev/nvme0n1";
        description = ''
          Where the slot lives.
          - `type = "partition"`: the block device. `"auto"` = detect from the
            root FS (findmnt → lsblk). `"/dev/nvme0n1"` = explicit. A second
            disk (`"/dev/nvme1n1"`) puts slots on a separate device.
          - `type = "regular-file"`: the directory holding the slot files.
        '';
      };
      label = mkOption {
        type = types.str;
        default = defaultLabel;
        defaultText = literalExpression ''
          "nix-store_1" for slot_a / "_empty" for slot_b
        '';
        description = ''
          GPT partition label (only `type = "partition"`). Ignored for
          `regular-file` (the filename comes from sysupdate's MatchPattern).
          Slot A conventionally is `"nix-store_1"`; slot B is `"_empty"` — the
          free-slot marker systemd-sysupdate hardcodes (it writes the `_empty`
          slot and relabels it to `"nix-store_<v>"`; vacuuming relabels back).
          The defaults match the stateless detection regex — do not set empty
          strings.
        '';
      };
    };
  };

  recoverySlotType = if partitions.enable then slotA.type else "partition";
  recoveryStorageA = if partitions.enable then slotA.storage else "auto";
  recoveryStorageB = if partitions.enable then slotB.storage else "auto";
  recoveryBootDir =
    if partitions.enable && !abImageActive && partitions.bootTarget != "auto"
    then partitions.bootTarget
    else "/boot/EFI/Linux";
  recoveryImageId = if partitions.enable then imageId' else imageId;

  # The provision script — bash, run as a oneshot BEFORE systemd-sysupdate.
  # Implements stateless detection (derive the slot layout from GPT labels,
  # never from a state file) + migration/wipe per `onSizeMismatch`.
  # Config values are BAKED INTO the script via Nix interpolation (no env-var
  # dependency — systemd's `environment` is hard to reach reliably through the
  # NixOS `script` wrapper chain). Bash-level variable expansion uses `''${...}`.
  provisionScript = pkgs.writeShellScript "nixtache-ab-provision" ''
    set -uo pipefail

    DISK_A="${slotA.storage}"
    DISK_B="${slotB.storage}"
    LABEL_A="${toString slotA.label}"
    LABEL_B="${toString slotB.label}"
    SLOT_SIZE="${partitions.slotSize}"
    AUTO_INIT="${if partitions.autoInit then "1" else "0"}"
    ON_MISMATCH="${partitions.onSizeMismatch}"
    PROTECTED="${concatStringsSep " " partitions.protectedLabels}"

    # -- resolve "auto" disk: find the device backing / ----------------------
    resolve_disk() {
      local d="$1"
      if [ "$d" = "auto" ]; then
        # /dev/nvme0n1p2 → /dev/nvme0n1  (strip trailing partition digit + optional 'p')
        findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//'
      else
        echo "$d"
      fi
    }

    # -- parse an absolute size to bytes -------------------------------------
    size_to_bytes() {
      local size="$1"
      if [[ "$size" =~ ^([0-9]+)([KMGTP]i?B?|[KMGTP]?)$ ]]; then
        local num="''${BASH_REMATCH[1]}"
        local unit="''${BASH_REMATCH[2]}"
        # strip optional iB / B suffix → keep just the letter
        unit="''${unit%iB}"; unit="''${unit%B}"
        case "$unit" in
          K)  echo $(( num * 1024 ));;
          M)  echo $(( num * 1024 * 1024 ));;
          G)  echo $(( num * 1024 * 1024 * 1024 ));;
          T)  echo $(( num * 1024 * 1024 * 1024 * 1024 ));;
          P)  echo $(( num * 1024 * 1024 * 1024 * 1024 * 1024 ));;
          "") echo "$num";;
          *)  echo "$num";;
        esac
      else
        echo "$size"
      fi
    }

    DISK=$(resolve_disk "$DISK_A")
    echo "nixtache-ab-provision: target disk = $DISK"

    # -- 1. detect GPT state via label count (stateless) --------------------
    # Two states only (fewer states = fewer bugs):
    #   Normal:  >=1 slot label (nix-store_N or _empty) → slots exist → check sizes
    #   Missing: 0 slot labels                         → no slots    → migration
    # Both label families count: `nix-store_N` is a written slot, `_empty` is
    # sysupdate's hardcoded free-slot marker. The active-vs-inactive choice is
    # made by the UKI (init= in cmdline); sysupdate manages the labels itself.
    has_slots=$(lsblk -no PARTLABEL "$DISK" 2>/dev/null | grep -cE 'nix-store_[0-9]|_empty' || true)
    echo "nixtache-ab-provision: nix-store slots on $DISK: $has_slots"

    # -- Normal state → size check -------------------------------------------
    if [ "$has_slots" -ge 1 ]; then
      expected_bytes=$(size_to_bytes "$SLOT_SIZE")
      # Find the actual size of the first slot partition via lsblk.
      # `-bno SIZE,PARTLABEL`: -b bytes, -n no header, -o columns; awk picks
      # the SIZE (col 1) of the first row whose PARTLABEL marks an A/B slot
      # (a written nix-store_N or a free _empty).
      actual_bytes=$(lsblk -bno SIZE,PARTLABEL "$DISK" 2>/dev/null | awk '/nix-store_[0-9]|_empty/{print $1; exit}')
      actual_bytes="''${actual_bytes:-0}"
      echo "nixtache-ab-provision: expected ~$expected_bytes bytes (slotSize=$SLOT_SIZE), actual $actual_bytes bytes"

      if [ "$actual_bytes" -ne "$expected_bytes" ]; then
        echo "nixtache-ab-provision: Size mismatch: slot is $actual_bytes bytes, configured slotSize is $expected_bytes bytes ($SLOT_SIZE)."

        if [ "$ON_MISMATCH" != "wipe" ]; then
          # onSizeMismatch=error: keep the slots and STOP sysupdate until the
          # conflict is resolved by hand — a silently-running sysupdate with a
          # wrong slot size would fail (or worse, truncate) every update.
          # `--runtime` mask: plain `mask` refuses to overwrite the
          # NixOS-managed unit symlink; the runtime mask lives in /run and the
          # provision unit (ordered before sysupdate, runs every boot) re-arms
          # it until the conflict is fixed.
          echo "nixtache-ab-provision: onSizeMismatch=error — keeping existing slots and masking systemd-sysupdate.service until the conflict is resolved." >&2
          echo "  To resolve: fix slotSize (or set onSizeMismatch=\"wipe\"), rebuild, then:" >&2
          echo "    systemctl unmask --runtime systemd-sysupdate.service && systemctl start nixtache-ab-provision.service" >&2
          systemctl mask --runtime systemd-sysupdate.service || { echo "nixtache-ab-provision: failed to mask systemd-sysupdate.service" >&2; exit 1; }
          exit 1
        fi

        # onSizeMismatch=wipe: check protected labels before touching anything.
        if [ -n "$PROTECTED" ]; then
          present_labels=$(lsblk -no PARTLABEL "$DISK" 2>/dev/null)
          for plabel in $PROTECTED; do
            if echo "$present_labels" | grep -q "$plabel"; then
              echo "nixtache-ab-provision: REFUSING wipe — protected label '$plabel' is present on $DISK. Partition untouched." >&2
              exit 1
            fi
          done
        fi

        echo "nixtache-ab-provision: onSizeMismatch=wipe — recreating both slots at $SLOT_SIZE."
        # Delete every A/B slot partition (written nix-store_* AND free _empty),
        # then recreate both at the new size with the configured labels
        # (conventionally nix-store_1 + _empty).
        del_nums=$(sgdisk -p "$DISK" 2>/dev/null | awk '/nix-store_[0-9]|_empty/{gsub(/[^0-9].*/,"",$1);print $1}' | sort -rn)
        for n in $del_nums; do
          sgdisk --delete="$n" "$DISK" || { echo "nixtache-ab-provision: failed to delete partition $n" >&2; exit 1; }
        done
        # After deleting all slot partitions the table may be empty —
        # next_part comes back blank; fall back to 1 (first partition).
        next_part=$(sgdisk -p "$DISK" 2>/dev/null | awk '/^ *[0-9]/{n=$1+1} END{print n}')
        [ -z "$next_part" ] && next_part=1
        # Resolve slotSize to a sgdisk-compatible +<n>M argument (sgdisk --new
        # does NOT accept percentages — only sectors, K, M, G, T, P).
        size_arg="+$(( $(size_to_bytes "$SLOT_SIZE") / 1048576 ))M"
        sgdisk --new="$next_part":0:"$size_arg" --typecode="$next_part":8300 --change-name="$next_part":"$LABEL_A" "$DISK" \
          || { echo "nixtache-ab-provision: failed to create $LABEL_A" >&2; exit 1; }
        sgdisk --new="$((next_part+1))":0:"$size_arg" --typecode="$((next_part+1))":8300 --change-name="$((next_part+1))":"$LABEL_B" "$DISK" \
          || { echo "nixtache-ab-provision: failed to create $LABEL_B" >&2; exit 1; }
        udevadm settle 2>/dev/null || true
        echo "nixtache-ab-provision: wipe done — both slots recreated ($LABEL_A + $LABEL_B) at $size_arg."
        exit 0
      fi

      echo "nixtache-ab-provision: slots present and correctly sized — nothing to do."
      exit 0
    fi

    # -- Missing state → migration -------------------------------------------
    if [ "$AUTO_INIT" != "1" ]; then
      echo "nixtache-ab-provision: A/B slots missing on $DISK and autoInit=false." >&2
      echo "  Set services.nixtache.deploy-target.ab.partitions.autoInit = true," >&2
      echo "  or provision manually (nixos-anywhere / sgdisk / dd)." >&2
      exit 1
    fi

    # autoInit=true → check free space.
    last_end=$(sgdisk -p "$DISK" 2>/dev/null | awk '/^ *[0-9]/{end=$3} END{print end+0}')
    disk_end=$(blockdev --getsz "$DISK" 2>/dev/null || echo 0)
    free_sectors=$(( disk_end - last_end ))
    free_bytes=$(( free_sectors * 512 ))
    slot_bytes=$(size_to_bytes "$SLOT_SIZE")
    needed_bytes=$(( slot_bytes * 2 ))

    echo "nixtache-ab-provision: free space = $free_bytes bytes, needed = $needed_bytes (2 x $SLOT_SIZE)"
    if [ "$free_bytes" -lt "$needed_bytes" ]; then
      echo "nixtache-ab-provision: Not enough free space for A/B slots: need $needed_bytes bytes (2 x $SLOT_SIZE = $SLOT_SIZE each), have $free_bytes bytes." >&2
      echo "  Options:" >&2
      echo "    1. Reduce slotSize to an explicit absolute size that fits the capacity plan." >&2
      echo "    2. Shrink root manually (ext4: resize2fs offline; btrfs: btrfs filesystem resize online; xfs/zfs: impossible)." >&2
      echo "    3. Use nixos-anywhere for a full wipe-and-reinstall (by SSH, no physical access)." >&2
      echo "    4. Add a second disk and put A/B slots there (slot_a.storage = \"/dev/nvme1n1\")." >&2
      echo "    5. Set autoInit = false and provision manually." >&2
      exit 1
    fi

    # Create the two slots. Resolve slotSize to +<n>M (sgdisk has no % support).
    next_part=$(sgdisk -p "$DISK" 2>/dev/null | awk '/^ *[0-9]/{n=$1+1} END{print n}')
    [ -z "$next_part" ] && next_part=1
    size_arg="+$(( $(size_to_bytes "$SLOT_SIZE") / 1048576 ))M"
    echo "nixtache-ab-provision: creating $LABEL_A (slot A) + $LABEL_B (slot B) at $size_arg each."
    sgdisk --new="$next_part":0:"$size_arg" --typecode="$next_part":8300 --change-name="$next_part":"$LABEL_A" "$DISK"
    sgdisk --new="$((next_part+1))":0:"$size_arg" --typecode="$((next_part+1))":8300 --change-name="$((next_part+1))":"$LABEL_B" "$DISK"
    udevadm settle 2>/dev/null || true
    echo "nixtache-ab-provision: A/B slots created on $DISK."
  '';

  recoveryScript = pkgs.writeShellScriptBin "nixtache-ab-recover" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.gptfdisk pkgs.findutils pkgs.gawk pkgs.gnused pkgs.systemd ]}:$PATH
    set -euo pipefail

    IMAGE_ID="${recoveryImageId}"
    SLOT_TYPE="${recoverySlotType}"
    DISK_A="${recoveryStorageA}"
    DISK_B="${recoveryStorageB}"
    BOOT_DIR="${recoveryBootDir}"
    LOWER_DB_DIR="/boot/EFI/nixtache"

    if [ "$#" -ne 1 ]; then
      echo "usage: nixtache-ab-recover <failed-version>" >&2
      exit 2
    fi
    FAILED_VERSION="$1"
    if [[ ! "$FAILED_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "nixtache-ab-recover: invalid version '$FAILED_VERSION'" >&2
      exit 2
    fi

    . /etc/os-release
    RUNNING_VERSION="''${IMAGE_VERSION:-}"
    if [ -z "$RUNNING_VERSION" ]; then
      echo "nixtache-ab-recover: IMAGE_VERSION is missing from /etc/os-release" >&2
      exit 1
    fi
    if [ "$FAILED_VERSION" = "$RUNNING_VERSION" ]; then
      echo "nixtache-ab-recover: refusing to remove running version $RUNNING_VERSION" >&2
      exit 1
    fi
    if systemctl is-active --quiet systemd-sysupdate-update.service || systemctl is-active --quiet systemd-sysupdate.service; then
      echo "nixtache-ab-recover: sysupdate is active; wait for it to finish before recovery" >&2
      exit 1
    fi

    count_lines() {
      awk 'NF { n++ } END { print n+0 }' <<< "$1"
    }

    UKI_MATCHES=""
    if [ -d "$BOOT_DIR" ]; then
      UKI_MATCHES=$(find "$BOOT_DIR" -maxdepth 1 -type f -name "''${IMAGE_ID}_''${FAILED_VERSION}+*.efi" -print)
    fi
    UKI_COUNT=$(count_lines "$UKI_MATCHES")
    if [ "$UKI_COUNT" -gt 1 ]; then
      echo "nixtache-ab-recover: refusing ambiguous deletion; multiple UKIs match version $FAILED_VERSION" >&2
      exit 1
    fi
    LOWER_DB="$LOWER_DB_DIR/''${IMAGE_ID}_''${FAILED_VERSION}.lower-db"

    remove_artifacts() {
      if [ "$UKI_COUNT" -eq 1 ]; then
        rm -f -- "$UKI_MATCHES"
      fi
      rm -f -- "$LOWER_DB"
    }

    resolve_disk() {
      local d="$1"
      if [ "$d" = "auto" ]; then
        findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//'
      else
        echo "$d"
      fi
    }

    if [ "$SLOT_TYPE" = "partition" ]; then
      DISK_A=$(resolve_disk "$DISK_A")
      DISK_B=$(resolve_disk "$DISK_B")
      DISKS=("$DISK_A")
      if [ "$DISK_B" != "$DISK_A" ]; then
        DISKS+=("$DISK_B")
      fi

      slot_partition_matches() {
        local label="nix-store_$1" disk
        for disk in "''${DISKS[@]}"; do
          lsblk -rpn -o NAME,PARTLABEL "$disk" 2>/dev/null \
            | awk -v disk="$disk" -v label="$label" '$2 == label { print $1, disk }'
        done
      }

      RUNNING_MATCHES=$(slot_partition_matches "$RUNNING_VERSION")
      FAILED_MATCHES=$(slot_partition_matches "$FAILED_VERSION")
      if [ "$(count_lines "$RUNNING_MATCHES")" -ne 1 ]; then
        echo "nixtache-ab-recover: expected exactly one running slot for $RUNNING_VERSION; refusing to continue" >&2
        exit 1
      fi
      if [ "$(count_lines "$FAILED_MATCHES")" -ne 1 ]; then
        echo "nixtache-ab-recover: expected exactly one failed slot for $FAILED_VERSION; refusing ambiguous deletion" >&2
        exit 1
      fi
      RUNNING_NODE=$(awk 'NR == 1 { print $1 }' <<< "$RUNNING_MATCHES")
      FAILED_NODE=$(awk 'NR == 1 { print $1 }' <<< "$FAILED_MATCHES")
      FAILED_DISK=$(awk 'NR == 1 { print $2 }' <<< "$FAILED_MATCHES")
      FAILED_PART=$(lsblk -no PARTN "$FAILED_NODE")
      if [ -z "$FAILED_PART" ] || [ "$FAILED_NODE" = "$RUNNING_NODE" ]; then
        echo "nixtache-ab-recover: failed and running slots are not distinct; refusing to continue" >&2
        exit 1
      fi

      sgdisk --change-name="$FAILED_PART":_empty "$FAILED_DISK" || exit 1
      udevadm settle 2>/dev/null || true
      if [ "$(lsblk -no PARTLABEL "$FAILED_NODE")" != "_empty" ]; then
        echo "nixtache-ab-recover: failed to mark $FAILED_NODE empty" >&2
        exit 1
      fi
      if [ "$(lsblk -no PARTLABEL "$RUNNING_NODE")" != "nix-store_$RUNNING_VERSION" ]; then
        echo "nixtache-ab-recover: running slot changed unexpectedly; aborting artifact cleanup" >&2
        exit 1
      fi
      remove_artifacts
      echo "nixtache-ab-recover: removed $FAILED_VERSION; running slot $RUNNING_NODE preserved and inactive slot is empty"
      exit 0
    fi

    if [ "$SLOT_TYPE" = "regular-file" ]; then
      STORE_DIRS=("$DISK_A")
      if [ "$DISK_B" != "$DISK_A" ]; then
        STORE_DIRS+=("$DISK_B")
      fi
      slot_file_matches() {
        find "''${STORE_DIRS[@]}" -maxdepth 1 -type f -name "''${IMAGE_ID}_$1.nix-store.raw" -print 2>/dev/null
      }
      RUNNING_MATCHES=$(slot_file_matches "$RUNNING_VERSION")
      FAILED_MATCHES=$(slot_file_matches "$FAILED_VERSION")
      if [ "$(count_lines "$RUNNING_MATCHES")" -ne 1 ] || [ "$(count_lines "$FAILED_MATCHES")" -ne 1 ]; then
        echo "nixtache-ab-recover: running and failed versions must each identify exactly one store file" >&2
        exit 1
      fi
      rm -f -- "$FAILED_MATCHES"
      if [ ! -f "$RUNNING_MATCHES" ] || [ -e "$FAILED_MATCHES" ]; then
        echo "nixtache-ab-recover: failed to restore a safe inactive-slot state" >&2
        exit 1
      fi
      remove_artifacts
      echo "nixtache-ab-recover: removed $FAILED_VERSION; running store file $RUNNING_MATCHES preserved"
      exit 0
    fi

    echo "nixtache-ab-recover: unsupported slot type '$SLOT_TYPE'" >&2
    exit 1
  '';
in
{
  options.services.nixtache.deploy-target.ab.partitions = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Provision A/B nix-store partition slots at boot. When set, the module
        runs `nixtache-ab-provision.service` (idempotent oneshot, BEFORE
        `systemd-sysupdate.service`) that guarantees the configured slot layout
        exists on disk: detects the current GPT state and migrates / size-checks
        / wipes as configured. `false` = slots must be created out-of-band
        (nixos-anywhere, manual sgdisk, etc.).

        This is the runtime counterpart to `modules/ab-image` (build-time): the
        image is built with `image.repart`, but `systemd-sysupdate` on the
        target can only WRITE an already-existing slot — it cannot CREATE one.
        See `doc/user_guide/ota.md`.
      '';
    };

    slot_a = mkOption {
      type = slotSubmod "nix-store_1";
      description = ''
        Slot A (the active nix-store partition the system boots from). Its
        `type` MUST match `slot_b.type` (sysupdate requires a uniform
        Target.Type across all instances of one transfer — asserted).
      '';
    };

    slot_b = mkOption {
      type = slotSubmod "_empty";
      description = ''
        Slot B (the free slot `systemd-sysupdate` writes the next image into).
        Conventionally labelled `"_empty"` — sysupdate's hardcoded free-slot
        marker; on the next apply sysupdate writes it and relabels it to
        `"nix-store_<v>"`.
      '';
    };

    slotSize = mkOption {
      type = types.str;
      example = "2G";
      description = ''
        Absolute size of EACH A/B slot (A and B are equal — squashFS/erofs
        constraint), such as `"2G"`, `"512M"`, or `"1024"` bytes. Explicit
        sizes produce the same layout on every disk. MUST match
        `services.nixtache.ab-image.storeSize` when both modules are enabled.
      '';
    };

    autoInit = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Create the A/B slots automatically when they're missing. `false`
        (default): if slots are absent → provision fails with a clear message
        pointing at manual options (nixos-anywhere / sgdisk / second disk).
        `true`: if slots are absent AND there's enough free space → create them
        via sgdisk. Only meaningful for `type = "partition"` (asserted).
        WARNING: `autoInit = true` with no pre-staged slot A means the system
        cannot boot from A/B until sysupdate fills the first slot.
      '';
    };

    onSizeMismatch = mkOption {
      type = types.enum [ "error" "wipe" ];
      default = "error";
      description = ''
        What to do when an existing slot's size differs from `slotSize`.
        - `"error"` (default): log the mismatch, keep the existing slots, mask
          `systemd-sysupdate.service` (updates stop) and fail the provision
          unit, until the operator resolves the conflict (fix `slotSize` or
          switch to `"wipe"`, then `systemctl unmask systemd-sysupdate.service`
          and re-run the provision unit).
        - `"wipe"`: delete BOTH slots and recreate them at the new `slotSize`
          (with the configured labels, conventionally `nix-store_1` + `_empty`).
          DESTRUCTIVE — slot A (current system) is lost; a deploy is REQUIRED
          before the next reboot (sysupdate fills the `_empty` slot). Refuses
          if a `protectedLabels` entry is present on the disk.
      '';
    };

    protectedLabels = mkOption {
      type = types.listOf types.str;
      default = [ "root" "esp" "boot" ];
      description = ''
        GPT partition labels the provision service NEVER touches. Before any
        `onSizeMismatch = "wipe"` operation, each label is scanned for on the
        target disk; if found, the wipe is REFUSED (the operator must resolve
        the size conflict manually or remove the protected partition from the
        disk). Conservative by design — prevents accidental data loss.
      '';
    };

    source = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://runner.example.com/ab-stage/myhost";
      description = ''
        OTA source the target pulls staged images from — written into the
        sysupdate transfer `Source` (this module owns the transfers when
        `partitions.enable = true`). Two deploy types, derived
        from the value:
        - remote: an `http(s)://...` URL → `Type = "url-file"` (target pulls
          from the runner host's staging over HTTP);
        - local: an absolute directory path → `Type = "regular-file"` with the
          plain path (self-deploy, staging populated locally; sysupdate
          rejects `file://` URIs for regular-file sources).
        `null` keeps a placeholder Source — override
        `systemd.sysupdate.transfers."10-nix-store".Source` directly instead.
      '';
    };

    imageId = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "myhost";
      description = ''
        Image id used in the sysupdate Source/Target MatchPatterns
        (`<imageId>_@v.nix-store.raw`). `null` (default) inherits
        `services.nixtache.ab-image.imageId` when the ab-image module is
        co-imported, falling back to `"nixtache"`. Set explicitly on targets
        that do NOT import ab-image (e.g. a plain host updated from a staging
        dir built elsewhere).
      '';
    };

    verify = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether sysupdate verifies the staged manifest signature
        (`Transfer.Verify`). Redundant when `publicKeyFile`/`publicKey` is set
        (a configured key implies verification, same convention as ab-image).
        `true` without a key fails the module assertion — the target needs the
        PUBLIC key (the deployer/runner host holds the PRIVATE signing key,
        `services.nixtache.runner.deploy.ab.signingKeyFile`).
      '';
    };

    publicKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the OpenPGP PUBLIC key (binary or ASCII-armored) matching the
        deployer's signing key. Installed as
        /etc/systemd/import-pubring.pgp (+ /usr/lib symlink, systemd#40702)
        and forces Transfer.Verify=yes — sysupdate then rejects staged
        manifests whose SHA256SUMS.gpg doesn't verify. Mutually exclusive
        with publicKey (one suffices). When the ab-image module is
        co-imported with its own key set, ab-image's pubring install wins.
      '';
    };

    publicKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ASCII-armored OpenPGP PUBLIC key, inline alternative to
        `publicKeyFile` (dearmored at build time). Same effect: pubring
        install + Transfer.Verify=yes.
      '';
    };

    bootTarget = mkOption {
      type = types.str;
      default = "auto";
      example = "/var/lib/nixtache/ab-slots/";
      description = ''
        Where the UKI (.efi) transfer lands. `"auto"` (default) = the ESP's
        `/EFI/Linux` via sysupdate's `$BOOT` partition autodiscovery
        (`PathRelativeTo = "boot"`) — same layout ab-image uses. Any other
        value is an absolute directory path (plain hosts or test VMs without
        an ESP). Only used when the ab-image module is NOT co-imported (on a
        real appliance ab-image owns the boot-image transfer).
      '';
    };
  };

  config = mkMerge [
    (mkIf (cfg.enable && ab.enable && partitions.enable) {
    # The remote A/B update/reboot sequence reads IMAGE_VERSION from
    # os-release to assess the booted version; a host
    # without it makes that trigger exit 1 silently. nixpkgs defaults the
    # version to "0" — warn so the omission is visible at eval time.
    warnings = lib.optionals (config.system.image.version == "0") [
      ''
        services.nixtache.deploy-target.ab.partitions: system.image.version
        is unset — the remote update/reboot sequence reads IMAGE_VERSION from
        os-release and fails without it.
        Set system.image.version (and system.image.id) on this host.
      ''
    ];

    assertions = [
      # Both slots must share one type: a sysupdate transfer requires a
      # uniform Target.Type across all its instances.
      {
        assertion = slotA.type == slotB.type;
        message = ''
          services.nixtache.deploy-target.ab.partitions: slot_a.type (${slotA.type}) != slot_b.type (${slotB.type}).
          systemd-sysupdate requires all instances of a transfer to have the same
          Target.Type. Set both to "partition" or both to "regular-file".
        '';
      }
      {
        assertion = !hasSuffix "%" partitions.slotSize;
        message = ''
          services.nixtache.deploy-target.ab.partitions.slotSize must be an
          explicit absolute size such as "2G", "512M", or a byte count, not
          "${partitions.slotSize}". Percentages make the partition layout
          depend on the attached disk; choose an absolute size from the
          capacity plan before provisioning.
        '';
      }
      {
        assertion =
          !abImagePresent
          || !abImage.enable or false
          || abImage.storeSize or partitions.slotSize == partitions.slotSize;
        message = ''
          services.nixtache.deploy-target.ab.partitions.slotSize (${partitions.slotSize})
          != services.nixtache.ab-image.storeSize (${abImage.storeSize or "?"}). The
          absolute sizes must match so the built image and provisioned slots
          have the same capacity.
        '';
      }
      # autoInit = true requires type = "partition".
      {
        assertion = !partitions.autoInit || isPartition;
        message = ''services.nixtache.deploy-target.ab.partitions: autoInit = true requires type = "partition" (can't auto-create regular files). '';
      }
      # Partition type requires storage = "auto" or a "/dev/..." node.
      {
        assertion =
          !isPartition
          || slotA.storage == "auto" || hasPrefix "/dev/" slotA.storage
          && (slotB.storage == "auto" || hasPrefix "/dev/" slotB.storage);
        message = ''services.nixtache.deploy-target.ab.partitions: partition type requires storage = "auto" or "/dev/..." (got slot_a="${slotA.storage}", slot_b="${slotB.storage}"). '';
      }
      # verify = true requires the OpenPGP pubring on the target.
      {
        assertion =
          !partitions.verify
          || builtins.hasAttr "systemd/import-pubring.pgp" config.environment.etc;
        message = ''
          services.nixtache.deploy-target.ab.partitions.verify = true, but no
          OpenPGP public key is shipped at /etc/systemd/import-pubring.pgp —
          sysupdate would reject every staged manifest. Set
          services.nixtache.deploy-target.ab.partitions.publicKeyFile (the
          PUBLIC key matching the deployer's signing key), or
          services.nixtache.ab-image.publicKeyFile when ab-image is co-imported.
        '';
      }
      # Partition type requires storage = "auto" or a "/dev/..." node.
      {
        assertion = !(partitions.publicKeyFile != null && partitions.publicKey != null);
        message = ''
          services.nixtache.deploy-target.ab.partitions: publicKeyFile and
          publicKey are both set. Pick one — publicKeyFile (path to the
          binary/armored PUBLIC key) OR publicKey (inline armored key).
        '';
      }
    ];

    # -- pubring install (target side of the signing pair) -------------------
    # The deployer signs with its PRIVATE key (runner module's signingKeyFile);
    # the target verifies with this PUBLIC key. Skipped when ab-image is
    # co-imported with its own key — its pubring install is authoritative.
    # /etc + /usr/lib symlink: the exclusive-override logic (systemd#40702)
    # means relying on /etc alone can fail. (optionalAttrs + leaf mkDefault:
    # mkIf-over-mkDefault on an attrsOf option silently drops the entry.)
    environment.etc = optionalAttrs (provisionPubring && !abImageHasKey) {
      "systemd/import-pubring.pgp".source = mkDefault pubringSource;
    };
    systemd.tmpfiles.rules = optionals (provisionPubring && !abImageHasKey) [
      "L+ /usr/lib/systemd/import-pubring.pgp - - - - ${pubringSource}"
    ];

    # -- provision service (partition type only) -----------------------------
    # Idempotent oneshot that runs BEFORE systemd-sysupdate at every boot,
    # detects the GPT state, and migrates / size-checks / wipes per config.
    # Regular-file targets skip this — sysupdate creates the backing files.
    systemd.services.nixtache-ab-provision = mkIf isPartition {
      description = "Provision A/B nix-store partition slots";
      before = [ "systemd-sysupdate.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ gptfdisk util-linux systemd gawk ];
      # Config values are baked into provisionScript via Nix interpolation —
      # no runtime env vars needed (the NixOS `script` wrapper chain makes
      # systemd `environment` unreliable for reaching the inner writeShellScript).
      script = ''
        ${provisionScript}
      '';
    };

    # -- sysupdate transfers (sole owner when active) -------------------------
    # Normal priority overrides ab-image's mkDefault. Same-disk → one transfer
    # (InstancesMax=2); different disks → two (InstancesMax=1 each); regular-
    # file → Target.Type = "regular-file" (sysupdate creates the files). The
    # UKI transfer is derived only without ab-image (appliances get it from
    # ab-image). sysupdate itself is enabled here (mkDefault) so a target
    # needs no manual `systemd.sysupdate` block at all.
    systemd.sysupdate.enable = mkDefault true;
    systemd.sysupdate.transfers = storeTransfers // bootTransfer;

    # Signature verification spawns `gpg2` from the service's PATH. nixpkgs
    # only equips the D-Bus `systemd-sysupdated` with gnupg — the plain
    # update oneshot has an empty PATH otherwise and every Verify=yes pull
    # fails with "Signature verification failed". systemd 262 renamed the
    # oneshot to systemd-sysupdate-update.service and kept the old name as a
    # compat alias; alias-named drop-ins are ignored, so the path goes on the
    # canonical name — the old-name entry stays for older pins where it WAS
    # the canonical unit.
    systemd.services.systemd-sysupdate-update = mkIf verifyEffective {
      path = [ pkgs.gnupgMinimal ];
    };
    systemd.services.systemd-sysupdate = mkIf verifyEffective {
      path = [ pkgs.gnupgMinimal ];
    };
    # The remote-update-with-reboot variant runs the same transfer set —
    # without gnupg in ITS PATH every Verify=yes pull dies with a broken
    # verifier pipe there too.
    systemd.services.systemd-sysupdate-reboot = mkIf verifyEffective {
      path = [ pkgs.gnupgMinimal ];
    };
    })
    (mkIf (cfg.enable && ab.enable && (partitions.enable || abImageActive)) {
      environment.systemPackages = [ recoveryScript ];
    })
  ];
}

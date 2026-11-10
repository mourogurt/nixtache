{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nixtache.overlay-nix;
  abCfg = config.services.nixtache.ab-image or { };
  abEnabled = abCfg.enable or false;
  imageId = abCfg.imageId or "nixtache";

  stateDir = "/var/lib/nixtache";
  runtimeState = "/run/nixtache-overlay";
  overlayBase = dirOf cfg.upperDir;
  slotsDir = "${overlayBase}/upper-slots";
  lowerStateLink = "${overlayBase}/lower-state";
  legacyBackup = "${overlayBase}/legacy-backup";
  stateNames = [ "db" "gcroots" "profiles" "temproots" ];

  shared = {
    inherit
      config
      lib
      pkgs
      cfg
      abEnabled
      imageId
      stateDir
      runtimeState
      overlayBase
      slotsDir
      lowerStateLink
      legacyBackup
      stateNames;
  };

  migration = import ./migration.nix shared;
  selection = import ./selection.nix (shared // {
    inherit migration;
    prepareScript = preparation.script;
  });
  preparation = import ./preparation.nix (shared // {
    inherit (selection) discoverySnippet metadataValueSnippet readyGenerationSnippet;
  });

  topologyModule = import ./topology.nix shared;
  systemdModule = import ./systemd.nix (shared // {
    prepareScript = preparation.script;
    selectionScript = selection.script;
    parentRootActivationSnippet = selection.parentRootActivationSnippet;
  });

  layerType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Stable overlay node identity used in the metaslot topology and on-disk layer path.";
      };
      parent = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Parent overlay node identity, or null for a direct child of the host overlay.";
      };
      upperDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's writable OverlayFS upper directory.";
      };
      workDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's OverlayFS work directory.";
      };
      stateDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's upper-owned Nix state directory.";
      };
      lowerRoot = mkOption {
        type = types.str;
        default = "/run/nixtache-runner-lower";
        description = "Read-only parent-lower root outside the child's relocated `/nix`.";
      };
    };
  };
in
{
  imports = [ topologyModule systemdModule ];

  options.services.nixtache.overlay-nix = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Layer a writable OverlayFS over `/nix/store` through Nix's experimental
        `local-overlay-store`. On A/B appliances, persistent upper files and Nix
        state are selected with the physical lower partition and preserved for
        rollback. Requires Nix >= 2.19.
      '';
    };

    upperDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/upper";
      description = ''
        Stable runtime path for the writable OverlayFS upper layer. On A/B
        appliances this path selects the current physical slot's upper
        metaslot. It must share a filesystem with `workDir`; use tmpfs for an
        ephemeral chain.
      '';
    };

    workDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/work";
      description = ''
        Stable runtime path for OverlayFS work metadata. Each slot generation
        receives an empty work directory on the same filesystem as `upperDir`.
      '';
    };

    upperOnUpdate = mkOption {
      type = types.enum [ "wipe" "reconcile" ];
      default = "wipe";
      description = ''
        Preparation policy for the inactive physical slot after a lower image
        installs. `"wipe"` creates an empty target upper and upper-owned Nix
        state. `"reconcile"` quiesces module-managed writers, clones the active
        upper chain, and repairs only that target copy against the new lower.
        The active upper is never wiped or repaired for a slot swap. An
        interrupted or incoherent target remains unready; booting an unprepared
        slot attempts target-only recovery before upper consumers start.
        Rollback selects the earlier slot's preserved chain without applying
        the policy again. Tmpfs uppers and all dependent overlay layers reset
        on every boot instead of using persistent metaslots.
      '';
    };

    _layers = mkOption {
      type = types.listOf layerType;
      default = [ ];
      internal = true;
      description = "Internal low-level declarations for focused storage fixtures; production nodes derive from runner containers.";
    };

    _topology = mkOption {
      type = types.attrs;
      default = { };
      internal = true;
      description = "Derived overlay nodes, parent index, preparation order and graph fingerprint for internal module consumers.";
    };
  };
}

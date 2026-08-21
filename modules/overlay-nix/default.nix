# nixosModules.overlay-nix — writable nix store overlay for A/B appliances.
#
# An A/B appliance mounts `/nix/store` from a read-only squashFS/erofs partition
# (slot A or B). That makes the store immutable — `nix shell`, `nix-env -i`,
# `nix build` all fail with "read-only store". This module layers a writable
# OverlayFS on top via Nix's experimental `local-overlay-store` store type,
# giving ad-hoc nix commands a writable upper layer while the lower (squashFS)
# stays untouched.
#
# Doc: https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
# Store URL: local-overlay://?lower-store=<L>&upper-layer=<U>
# Experimental feature: `local-overlay-store` (landed in Nix 2.19, not 2.35 —
# the /2.35/ doc URL is misleading; the feature is stable in the manual since 2.22).
#
# What the module does when `enable = true`:
#   1. Re-enables nix on appliances (`nix.enable = mkOverride 900 true` — the
#      image-based-appliance profile forces `nix.enable = false` at normal
#      priority; 900 beats it WITHOUT mkForce, so a consumer can still force-off).
#   2. tmpfiles: create `upperDir` + `workDir` (the writable layer + OverlayFS
#      workdir).
#   3. `nix-daemon-overlay-mount.service`: mount OverlayFS AT `/nix/store` —
#      lowerdir = `/nix/store` (ro squashFS), upperdir = `upperDir`, workdir =
#      `workDir`. The merged view IS `/nix/store` (default root for the
#      local-overlay store). Runs before `nix-daemon` so the daemon always sees
#      the merged view.
#   4. `nix.settings.store = local-overlay://…` — the SYSTEM nix-daemon serves
#      the overlay store (not a side daemon). Every nix command (`nix run`,
#      `nix shell`, `nix build`, `nix-store --realize`, `nix-collect-garbage`)
#      talks to the daemon via the standard socket and gets the layered store.
#   5. `ignore-gc-delete-failure=true` — GC deletes upper-layer paths; lower
#      (squashFS) delete failures are ignored as warnings (lower is read-only).
#
# Assert: requires Nix ≥ 2.19 (the experimental feature is absent in earlier
# versions — `nix-daemon` would reject the store URL).
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nixtache.overlay-nix;

  # local-overlay store URL served by the SYSTEM nix-daemon. No `root=`
  # parameter → defaults to `/` (merged store at `/nix/store`, matching the
  # OverlayFS mount point). `lower-store=local` — the DEFAULT local store (root
  # `/`, store dir `/nix/store`) provides the read-only squashFS lower layer.
  # NOT `daemon` (the daemon can't be its own lower store — circular reference).
  # NOT a path like `/nix/store` (resolves its store dir to `/nix/store/nix/store`).
  # `upper-layer` is where writes land; `ignore-gc-delete-failure=true` lets GC
  # reap upper paths while treating lower delete failures as warnings.
  # `check-mount=false`: the overlay is an OVERMOUNT on /nix/store (lowerdir ==
  # mountpoint, the squashFS). The default check-mount=true reads /proc/mounts
  # and expects lowerdir to be a DIFFERENT path than the mountpoint — an
  # overmount fails that check even though the kernel handles it correctly.
  overlayStoreUrl = "local-overlay://"
    + "?lower-store=local"
    + "&upper-layer=${cfg.upperDir}"
    + "&ignore-gc-delete-failure=true"
    + "&check-mount=false";
in
{
  options.services.nixtache.overlay-nix = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Layer a writable OverlayFS on top of the read-only `/nix/store` (squashFS
        or erofs on an A/B appliance) via Nix's experimental `local-overlay-store`
        store type. Enables ad-hoc `nix shell`, `nix-env -i`, `nix build` on a
        machine whose system store is immutable. The lower (squashFS) layer is
        never modified — writes go to `upperDir`; GC reaps upper paths and
        ignores lower delete failures (`ignore-gc-delete-failure=true`).

        Re-enables nix on appliances (`nix.enable = mkOverride 900 true`, beating
        the appliance profile's `nix.enable = false` without mkForce). Requires
        Nix ≥ 2.19 (the `local-overlay-store` experimental feature).
      '';
    };

    upperDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/upper";
      description = ''
        Writable OverlayFS upper layer. Where additionally-installed store paths
        land. Persistent on the root FS (survives reboot) by default — set to a
        tmpfs path (`/tmp/nix-overlay/upper`) for RAM-only, ephemeral installs.
        MUST be on the same filesystem as `workDir` (OverlayFS constraint).
      '';
    };

    workDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/work";
      description = ''
        OverlayFS work directory (kernel-internal metadata). MUST be on the same
        filesystem as `upperDir`.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          (builtins.compareVersions config.nix.package.version "2.19") >= 0;
        message = ''
          services.nixtache.overlay-nix.enable = true requires Nix >= 2.19
          (experimental feature `local-overlay-store`; present since 2.19, NOT
          2.35 — the nix.dev /2.35/ doc URL is misleading). Current:
          ${config.nix.package.version}.
        '';
      }
    ];

    # Re-enable nix on appliances. The image-based-appliance profile sets
    # `nix.enable = false` as a PLAIN assignment (priority 100). mkOverride 99
    # beats it (99 < 100) WITHOUT mkForce — a consumer can still force nix off
    # with `mkForce false` (priority 50) if needed.
    nix.enable = mkOverride 99 true;

    # Point the default store at the local-overlay store. Every nix command
    # (run/shell/build/realise/GC) talks to the system daemon via the standard
    # socket and gets the layered view.
    nix.settings.store = overlayStoreUrl;
    nix.settings.extra-experimental-features = [ "nix-command" "flakes" "local-overlay-store" ];
    # A/B appliances are typically offline — the global flake registry download
    # would fail and block every `nix run/shell/build`. Disable it; local
    # registry entries (nix.registry.*) still work.
    nix.settings.flake-registry = "";

    # Create upper + work directories.
    systemd.tmpfiles.rules = [
      "d ${cfg.upperDir} 0755 root root -"
      "d ${cfg.workDir} 0755 root root -"
    ];

    # ── OverlayFS mount service ────────────────────────────────────────────
    # Mounts the merged view AT `/nix/store` (overmounting the read-only
    # squashFS). The kernel allows stacking: the squashFS stays mounted
    # underneath, the OverlayFS merges it with the writable upper layer.
    # Runs before nix-daemon so the daemon always sees the merged view.
    systemd.services.nix-daemon-overlay-mount = {
      description = "Mount OverlayFS for the nix local-overlay-store";
      wantedBy = [ "multi-user.target" ];
      # After local-fs.target: the squashFS /nix/store must be mounted first.
      # Before nix-daemon.service (NOT .socket — that would create an ordering
      # cycle: mount→socket→sockets.target→basic.target→multi-user.target→mount).
      after = [ "local-fs.target" ];
      before = [ "nix-daemon.service" ];
      path = with pkgs; [ util-linux coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Skip if OUR overlay is already mounted at /nix/store (idempotent on
        # restart). Check for our specific upperdir — the NixOS test framework
        # mounts its OWN overlay at /nix/store (host store + tmpfs upper); that
        # must NOT prevent us from stacking ours on top.
        if mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=${cfg.upperDir}'; then
          echo "overlay already mounted at /nix/store (upperdir=${cfg.upperDir})"
          exit 0
        fi
        mount -t overlay overlay \
          -o lowerdir=/nix/store \
          -o upperdir=${cfg.upperDir} \
          -o workdir=${cfg.workDir} \
          /nix/store
      '';
    };

    # Make the nix-daemon wait for the overlay mount. The daemon is
    # socket-activated: the SOCKET is created early (sockets.target) so late
    # connections work; the SERVICE (started on first connect) waits for the
    # mount via after+requires. The socket itself must NOT require the mount —
    # sockets.target precedes multi-user.target, so a requires on the mount
    # would deadlock the socket.
    systemd.services.nix-daemon = {
      after = [ "nix-daemon-overlay-mount.service" ];
      requires = [ "nix-daemon-overlay-mount.service" ];
    };
  };
}

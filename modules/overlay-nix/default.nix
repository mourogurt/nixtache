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
#   4. `nix.settings.store = local-overlay://...` — the SYSTEM nix-daemon serves
#      the overlay store (not a side daemon). Every nix command (`nix run`,
#      `nix shell`, `nix build`, `nix-store --realize`, `nix-collect-garbage`)
#      talks to the daemon via the standard socket and gets the layered store.
#   5. `ignore-gc-delete-failure=true` — GC deletes upper-layer paths; lower
#      (squashFS) delete failures are ignored as warnings (lower is read-only).
#
# Assert: requires Nix >= 2.19 (the experimental feature is absent in earlier
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
  # `remount-hook` is a STORE-level setting (URL parameter, not nix.conf):
  # GC's dedup path deletes upper copies of lower-valid paths directly
  # through the upperdir, and the hook rebuilds the overlay mount afterwards
  # so the kernel's merged view stays coherent (stale-dentry protection).
  # `check-mount=false`: the overlay is an OVERMOUNT on /nix/store (lowerdir ==
  # mountpoint, the squashFS). The default check-mount=true reads /proc/mounts
  # and expects lowerdir to be a DIFFERENT path than the mountpoint — an
  # overmount fails that check even though the kernel handles it correctly.
  overlayStoreUrl = "local-overlay://"
    + "?lower-store=local"
    + "&upper-layer=${cfg.upperDir}"
    + "&ignore-gc-delete-failure=true"
    + "&remount-hook=${remountHook}"
    + "&check-mount=false";

  stateDir = "/var/lib/nixtache";
  lifecycleMarker = "${stateDir}/last-boot-image-version";

  # After GC deletes upper-layer files directly through the upperdir (the
  # local-overlay-store dedup path — deleting via the merged view would leave
  # an OverlayFS whiteout masking the lower copy), Nix calls the remount hook
  # because the kernel may keep stale dentries for the bypassed deletions. A
  # plain `mount -o remount` does not reliably invalidate them, so the hook
  # rebuilds the overlay mount from its option set (EBUSY retries cover
  # transient holders; exec'd binaries never block umount).
  remountHook = pkgs.writeShellScript "nixtache-overlay-remount" ''
    export PATH=${lib.makeBinPath [ pkgs.util-linux pkgs.coreutils ]}
    mountpoint="''${1:-/nix/store}"
    i=0
    while ! umount "$mountpoint"; do
      i=$((i + 1))
      if [ "$i" -ge 10 ]; then
        echo "nixtache-overlay-remount: $mountpoint still busy after 10 tries — leaving the old mount in place (retry on the next GC)" >&2
        exit 0
      fi
      sleep 1
    done
    mount -t overlay overlay \
      -o lowerdir="$mountpoint" \
      -o upperdir=${cfg.upperDir} \
      -o workdir=${cfg.workDir} \
      "$mountpoint"
  '';

  clearUpperState = ''
    find ${cfg.upperDir} -mindepth 1 -delete
    find ${cfg.workDir} -mindepth 1 -delete
    rm -rf /nix/var/nix/db* /nix/var/nix/gcroots /nix/var/nix/profiles /nix/var/nix/temproots
  '';

  tmpfsResetScript = ''
    set -euo pipefail
    if [ ! -f /etc/image-version ]; then
      echo "nixtache-overlay-tmpfs-reset: no appliance image version; nothing to reset"
      exit 0
    fi
    upperFs=$(findmnt -T ${cfg.upperDir} -n -o FSTYPE)
    if [ "$upperFs" != "tmpfs" ]; then
      echo "nixtache-overlay-tmpfs-reset: upper is persistent; nothing to reset"
      exit 0
    fi
    echo "nixtache-overlay-tmpfs-reset: clearing state for the ephemeral upper"
    ${clearUpperState}
  '';

  lifecycleScript = ''
    set -euo pipefail
    marker=${lifecycleMarker}
    if [ ! -f /etc/image-version ]; then
      echo "nixtache-overlay-lifecycle: no appliance image version; nothing to do"
      exit 0
    fi
    version=$(cat /etc/image-version) || exit 1
    if [ -z "$version" ]; then
      echo "nixtache-overlay-lifecycle: /etc/image-version is empty" >&2
      exit 1
    fi
    if [ ! -f "$marker" ]; then
      mkdir -p ${stateDir}
      printf '%s\n' "$version" > "$marker"
      echo "nixtache-overlay-lifecycle: recorded baseline image version $version"
      exit 0
    fi
    recorded=$(cat "$marker") || exit 1
    if [ "$recorded" = "$version" ]; then
      echo "nixtache-overlay-lifecycle: image version $version already handled"
      exit 0
    fi
    upperFs=$(findmnt -T ${cfg.upperDir} -n -o FSTYPE)
    if [ "$upperFs" = "tmpfs" ]; then
      printf '%s\n' "$version" > "$marker"
      echo "nixtache-overlay-lifecycle: ephemeral upper reset for image version $version"
      exit 0
    fi
    ${if cfg.upperOnUpdate == "wipe" then ''
      echo "nixtache-overlay-lifecycle: wiping the upper for image version $version"
      ${clearUpperState}
      printf '%s\n' "$version" > "$marker"
      echo "nixtache-overlay-lifecycle: wipe complete"
    '' else ''
      fail=0
      sysp=$(readlink -f /run/current-system 2>/dev/null || true)
      [ -n "$sysp" ] || sysp=$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)
      roots=$(
        {
          find /nix/var/nix/gcroots -mindepth 1 -maxdepth 1 -type l ! -name system 2>/dev/null | while read -r l; do
            readlink -f "$l" || true
          done
          find /nix/var/nix/gcroots/auto -type l 2>/dev/null | while read -r l; do
            readlink -f "$l" || true
          done
          find /nix/var/nix/profiles/per-user -maxdepth 2 -type l 2>/dev/null | while read -r l; do
            readlink -f "$l" || true
          done
        } | grep '^/nix/store/' | sort -u | grep -v -F "$sysp" || true
      )
      echo "nixtache-overlay-lifecycle: pass 1 — invalidate DB entries whose files vanished from the merged store"
      nix-store --verify || true
      echo "nixtache-overlay-lifecycle: pass 2 — re-fetch missing closure paths of the live roots"
      for root in $roots; do
        if ! requisites=$(nix-store -q --requisites "$root" 2>/dev/null); then
          echo "nixtache-overlay-lifecycle: repairing $root to recover its closure records"
          if ! nix-store --repair-path "$root"; then
            echo "nixtache-overlay-lifecycle: cannot repair $root (substituter unreachable or missing path)" >&2
            fail=1
            continue
          fi
          if ! requisites=$(nix-store -q --requisites "$root" 2>/dev/null); then
            echo "nixtache-overlay-lifecycle: cannot enumerate the closure of $root after repair" >&2
            fail=1
            continue
          fi
        fi
        for p in $requisites; do
          if [ ! -e "$p" ]; then
            echo "nixtache-overlay-lifecycle: repairing $p (files absent from the merged store)"
            if ! nix-store --repair-path "$p"; then
              echo "nixtache-overlay-lifecycle: cannot repair $p (substituter unreachable or missing path)" >&2
              fail=1
            fi
          fi
        done
      done
      if [ "$fail" = 0 ]; then
        printf '%s\n' "$version" > "$marker"
        echo "nixtache-overlay-lifecycle: reconcile complete for image version $version"
      else
        echo "nixtache-overlay-lifecycle: reconcile incomplete for image version $version; retry left pending" >&2
        exit 1
      fi
    ''}
  '';
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
        Nix >= 2.19 (the `local-overlay-store` experimental feature).
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

    upperOnUpdate = mkOption {
      type = types.enum [ "wipe" "reconcile" ];
      default = "wipe";
      description = ''
        Lifecycle policy for a persistent writable upper layer across A/B slot
        cutovers. The policy runs on the first boot whose `/etc/image-version`
        differs from `/var/lib/nixtache/last-boot-image-version`, not when an
        update is attempted. No-op and rejected updates leave the upper
        untouched. An absent marker records the running version as a baseline
        without running the policy; a rollback to a different version runs it
        again.

        - `"wipe"` (default): at cutover boot, clear the upper layer, its work
          directory and the overlay store state under `/nix/var/nix` before
          the lower store database is reseeded and the overlay mounts. This
          deterministic, substituter-independent policy discards ad-hoc
          installs at each cutover.
        - `"reconcile"`: after the lower database loads and the overlay mounts
          at cutover boot, resolve persistent gc-root and user-profile targets
          live, invalidate records whose files vanished with
          `nix-store --verify`, and fetch only missing closure paths with
          `nix-store --repair-path`. Repair needs a substituter that serves the
          old references. Failure leaves the lifecycle marker pending so the
          pass retries on the next boot or when
          `nixtache-overlay-lifecycle.service` is restarted; the boot itself is
          unaffected.

        On tmpfs, upper-owned Nix state is instead reset on every boot before
        the lower database is reseeded and the overlay mounts, including when
        the image version is unchanged. No persistent upper content exists to
        wipe or reconcile in that case.

        Migration from the removed `"none"` value: configurations that set it
        explicitly fail evaluation (this enum lists the two valid values);
        configurations that never set the option use `"wipe"`. Choose
        `"reconcile"` with a suitable substituter to carry persistent ad-hoc
        installs across cutovers.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
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
    nix.settings.extra-experimental-features = [ "nix-command" "flakes" "local-overlay-store" "ca-derivations" ];
    # A/B appliances are typically offline — the global flake registry download
    # would fail and block every `nix run/shell/build`. Disable it; local
    # registry entries (nix.registry.*) still work.
    nix.settings.flake-registry = "";

    # Create upper + work directories.
    systemd.tmpfiles.rules = [
      "d ${cfg.upperDir} 0755 root root -"
      "d ${cfg.workDir} 0755 root root -"
    ];

    # -- OverlayFS mount service --------------------------------------------
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
    }

    (mkIf (config.system.image.version != null && config.system.image.version != "") {
    environment.etc."image-version".text = mkDefault config.system.image.version;
    })

    {
    systemd.services.nixtache-overlay-tmpfs-reset = {
      description = "Reset stale Nix state for a tmpfs overlay upper";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "zfs-mount.service" ];
      before = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" ];
      path = with pkgs; [ coreutils findutils util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = tmpfsResetScript;
    };

    systemd.services.nixtache-overlay-lifecycle = {
      description = "nixtache overlay-nix: ${cfg.upperOnUpdate} the upper layer at slot cutover";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ coreutils findutils gnugrep util-linux ]
        ++ optional (cfg.upperOnUpdate == "reconcile") config.nix.package;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lifecycleScript;
    };

    systemd.services.nix-daemon-overlay-mount = {
      after = [ "nixtache-overlay-tmpfs-reset.service" ];
      requires = [ "nixtache-overlay-tmpfs-reset.service" ];
    };
    systemd.services.nixtache-lower-store-db-load = {
      after = [ "nixtache-overlay-tmpfs-reset.service" ];
      requires = [ "nixtache-overlay-tmpfs-reset.service" ];
    };
    }

    (mkIf (cfg.upperOnUpdate == "wipe") {
    systemd.services.nixtache-overlay-lifecycle = {
      after = [ "local-fs.target" "zfs-mount.service" "nixtache-overlay-tmpfs-reset.service" ];
      before = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" ];
      requires = [ "nixtache-overlay-tmpfs-reset.service" ];
    };
    systemd.services.nix-daemon-overlay-mount = {
      after = [ "nixtache-overlay-lifecycle.service" ];
      requires = [ "nixtache-overlay-lifecycle.service" ];
    };
    systemd.services.nixtache-lower-store-db-load = {
      after = [ "nixtache-overlay-lifecycle.service" ];
      requires = [ "nixtache-overlay-lifecycle.service" ];
    };
    })

    (mkIf (cfg.upperOnUpdate == "reconcile") {
    systemd.services.nixtache-overlay-lifecycle = {
      after = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" ];
      requires = [ "nixtache-overlay-tmpfs-reset.service" "nix-daemon-overlay-mount.service" ];
    };
    })
  ]);
}

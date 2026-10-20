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
  captureDir = "${stateDir}/overlay-capture";
  reconcileMarker = "${stateDir}/overlay-reconcile-pending";

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

  # Wipe runs at the update boundary: everything the overlay store created —
  # the upper layer contents, the OverlayFS work dir and the nix state under
  # /nix/var/nix (database, gcroots, profiles) — is deleted so the next boot
  # mounts a pristine overlay over the NEW lower image. On an appliance these
  # paths hold overlay-created state only (the system itself boots from the
  # squashFS lower and carries no system profiles here). The daemon is stopped
  # for the wipe and restarted right away: sysupdate may find nothing new
  # (no-op update) and the machine must keep working without a reboot; a
  # realize racing the wipe loses its progress coherently (files and database
  # entries vanish together).
  wipeScript = ''
    set -euo pipefail
    echo "nixtache-overlay-preupdate: wiping the overlay upper layer and store DB state"
    systemctl stop nix-daemon.service
    find ${cfg.upperDir} -mindepth 1 -delete
    find ${cfg.workDir} -mindepth 1 -delete
    rm -rf /nix/var/nix/db* /nix/var/nix/gcroots /nix/var/nix/profiles /nix/var/nix/temproots
    systemctl start nix-daemon.service
    echo "nixtache-overlay-preupdate: wipe complete"
  '';

  # Capture records the store paths that must exist again after the swap:
  # every gc-root symlink target plus every USER profile link target (the
  # top-level `system` profile is deliberately excluded — on an appliance it
  # tracks the booted generation whose closure comes from the slot images,
  # and repairing it would re-download the entire old closure delta). A
  # profile's own store path covers its whole closure — realizing it restores
  # all its entries in one shot, no manifest parsing needed. The reconcile
  # marker arms the post-boot pass.
  captureScript = ''
    set -euo pipefail
    echo "nixtache-overlay-preupdate: capturing overlay roots for post-update reconcile"
    mkdir -p ${captureDir}
    # Indirect roots point at the ROOT FILE (any path), not the store path
    # — resolve each chain with readlink -f and keep what lands in the
    # store. The SYSTEM profile chain is excluded on both paths (profiles/
    # top level and its gcroots/system alias): on an appliance it tracks the
    # booted generation whose closure comes from the slot images, and
    # repairing it would re-download the entire old closure delta.
    # `|| true`: with no roots on the machine grep exits 1 on empty input —
    # an empty roots.txt is a valid capture (reconcile skips).
    # System-created roots (the profile symlink and the activation-time
    # auto-root) point at the CURRENT system toplevel — excluded on both
    # paths: after the swap the new lower provides the new closure, and
    # repairing the old toplevel would re-download its entire delta.
    sysp=$(readlink -f /run/current-system 2>/dev/null || true)
    [ -n "$sysp" ] || sysp=$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)
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
    } | grep '^/nix/store/' | sort -u | grep -v -F "$sysp" > ${captureDir}/roots.txt || true
    touch ${reconcileMarker}
    echo "nixtache-overlay-preupdate: $(wc -l < ${captureDir}/roots.txt) roots captured"
  '';

  # Reconcile heals the upper layer after a swap replaced the lower image.
  # Pass 1 (`nix-store --verify`) auto-invalidates database entries whose
  # files are gone from the merged store and have no valid referrers — its
  # exit code is ADVISORY: referrer-protected danglers (a dependency of a
  # still-present upper path) are left valid on purpose and can even trip a
  # harmless FOREIGN KEY message during the invalidation attempt; pass 2 is
  # what heals them. Pass 2 walks the closure of every recorded root and
  # re-fetches (`nix-store --repair-path`) exactly the paths whose files are
  # missing from the merged view — a delta repair: present paths are not
  # touched. The marker is consumed only on full success — a failed pass
  # keeps the unit red and the next boot (or a manual restart) retries. The
  # unit hard-requires the overlay mount: verifying against the bare
  # squashFS (overlay not yet mounted) would invalidate every upper entry.
  reconcileScript = ''
    set -uo pipefail
    fail=0
    echo "nixtache-overlay-reconcile: pass 1 — invalidate DB entries whose files vanished from the merged store"
    nix-store --verify || true
    echo "nixtache-overlay-reconcile: pass 2 — re-fetch missing closure paths of the recorded roots"
    if [ -f ${captureDir}/roots.txt ]; then
      while read -r root; do
        [ -n "$root" ] || continue
        for p in $(nix-store -q --requisites "$root" 2>/dev/null || echo "$root"); do
          if [ ! -e "$p" ]; then
            echo "nixtache-overlay-reconcile: repairing $p (files absent from the merged store)"
            if ! nix-store --repair-path "$p"; then
              echo "nixtache-overlay-reconcile: cannot repair $p (substituter unreachable or missing path)" >&2
              fail=1
            fi
          fi
        done
      done < ${captureDir}/roots.txt
    fi
    if [ "$fail" = 0 ]; then
      rm -f ${reconcileMarker}
      echo "nixtache-overlay-reconcile: consistent — marker consumed"
    else
      echo "nixtache-overlay-reconcile: incomplete — marker kept for retry" >&2
      exit 1
    fi
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

    upperOnUpdate = mkOption {
      type = types.enum [ "wipe" "reconcile" ];
      default = "wipe";
      description = ''
        Lifecycle policy for the writable upper layer across A/B (OTA) updates.
        A slot swap replaces the read-only lower store, which — with the
        shipped lower store database — deterministically leaves upper paths
        referencing files that only existed in the old lower image. There is
        no carry-over value: the policy applies whenever an update is
        triggered, on every appliance shape (OTA on/off × overlay on/off
        reduces to "no updates happen" when OTA is off, where the hook is
        inert).

        - `"wipe"` (default): before `systemd-sysupdate` writes the inactive
          slot, the upper layer, its work dir and the overlay store state
          under `/nix/var/nix` are cleared. Disposable-upper policy:
          deterministic and substituter-independent, but ad-hoc installs do
          not survive an update. The nix daemon is stopped for the wipe and
          restarted right away (a no-op update must leave a working machine).
          The shipped lower store database is re-seeded from the slot's dump
          at the next boot.
        - `"reconcile"`: before the update, gc-roots and profile targets are
          captured to `/var/lib/nixtache/overlay-capture`; after the reboot a
          reconcile pass runs `nix-store --verify` (drops database entries
          whose files are gone and that nothing valid refers to) and then
          re-fetches, for every recorded root, exactly the closure paths
          whose files are absent from the merged store
          (`nix-store --repair-path` — a delta repair; present paths are not
          touched). Repair needs a substituter that still serves the old
          references (e.g. the runner's binary cache); without it the
          reconcile unit fails red, the boot is unaffected and the pass
          retries on the next boot or a manual restart.

        Migration from the removed `"none"` value: configurations that set it
        explicitly fail evaluation (this enum lists the two valid values);
        configurations that never set the option move to `"wipe"`. To keep a
        carried upper across updates, choose `"reconcile"` with a substituter
        that serves the old lower's paths.
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
    }

    {
    # Lifecycle hook: one drop-in attachment point covers every update
    # trigger (the deploy action's SSH trigger, the idle-gated
    # nixtache-ab-apply, the auto-update poll and sysupdate's own timer) —
    # starting systemd-sysupdate always pulls the pre-update unit first.
    # Unconditional: with only wipe/reconcile values left, a policy always
    # applies (on hosts without OTA the hook simply never gets triggered).
    systemd.services.nixtache-overlay-preupdate = {
      description = "nixtache overlay-nix: ${cfg.upperOnUpdate} the upper layer before an A/B update";
      before = [ "systemd-sysupdate.service" ];
      path = with pkgs; [ systemd coreutils findutils gnugrep ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = if cfg.upperOnUpdate == "wipe" then wipeScript else captureScript;
    };

    # Plain oneshot (no RemainAfterExit): every sysupdate start re-runs the
    # hook, so a failed first update attempt re-wipes/re-captures on retry.
    systemd.services.systemd-sysupdate = {
      wants = [ "nixtache-overlay-preupdate.service" ];
      after = [ "nixtache-overlay-preupdate.service" ];
    };
    }

    (mkIf (cfg.upperOnUpdate == "reconcile") {
    systemd.services.nixtache-overlay-reconcile = {
      description = "nixtache overlay-nix: reconcile the upper layer with the new lower image";
      wantedBy = [ "multi-user.target" ];
      # HARD dependency on the overlay mount: verifying against the bare
      # squashFS (overlay not yet mounted) would invalidate every upper
      # entry — the exact damage the pass is meant to repair.
      after = [ "nix-daemon-overlay-mount.service" ];
      requires = [ "nix-daemon-overlay-mount.service" ];
      unitConfig = {
        ConditionPathExists = reconcileMarker;
      };
      path = [ pkgs.coreutils config.nix.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = reconcileScript;
    };
    })
  ]);
}

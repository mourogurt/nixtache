# Live activation via a root systemd unit — the V2 design (no deploy-rs, no
# sudo/doas/run0). See doc/specs/direct-deploy/0001 §7.2/§9.2 (revised).
#
# The runner pushes a built closure to the target with `nix copy --to`, drops
# its store path into `/var/lib/nixtache/pending-system`, and triggers:
#
#     ssh <deploy-user>@<host> 'systemctl start nixtache-apply.service'
#
# This unit (root, started by the deploy user via polkit) does the entire
# activation atomically:
#   1. read the staged closure path from the pointer file;
#   2. `nix-env -p .../system --set <closure>` + `switch-to-configuration switch`;
#   3. Tier-1 probe: poll `systemctl is-active --wait <unit>` for every
#      `criticalUnits` in the `healthCheckTimeout` window (B1 — runs ON the
#      target as root, so it works even if the new config broke sshd);
#   4. on probe failure, revert the system profile to the pre-apply closure and
#      re-activate it, then exit non-zero (the action turns the job red).
#
# The deploy user is authorized ONLY to `start nixtache-apply.service` (polkit
# rule) and to write the pointer file (`nixtache-deploy` group). No escalation
# tool is involved at all — that's the whole point of going systemd-native.
#
# For `method = "ab-image"` targets this unit is irrelevant (sysupdate writes
# the inactive slot); ab-image is wired in a later batch.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.deploy-target;
  du = cfg.deployUser;
  # The deploy user the polkit rule authorizes. Falls back to the default name
  # when deployUser is null (consumer manages auth out-of-band but still wants
  # the unit + polkit wired for that canonical user).
  duName = if du != null then du.name else "nixos-deploy";

  stateDir = "/var/lib/nixtache";
  pendingFile = "${stateDir}/pending-system";
  pendingDryFile = "${stateDir}/pending-dry";
in
{
  config = mkIf cfg.enable {
    # polkit is required: it's how the deploy user is authorized to start the
    # apply unit. Force it on (the whole transport depends on it).
    security.polkit.enable = true;

    # Pointer dir: writable by the deploy user via the `nixtache-deploy` group.
    # The group lives here (not user.nix): the dir/unit exist whenever the
    # target is enabled, even with deployUser = null (timer-only targets).
    users.groups.nixtache-deploy = { };
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0770 root nixtache-deploy -"
    ];

    # --- the apply unit (root) ----------------------------------------------
    systemd.services.nixtache-apply = {
      description = "nixtache direct-deploy: activate a staged system closure, probe criticalUnits, roll back on failure";
      path = with pkgs; [ systemd nix coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      # `set -u` (catch typos) + explicit error handling (no `set -e` — we want
      # to run the rollback branch on switch/probe failure rather than exit
      # mid-script).
      script = let
        # Probe chain: ALL criticalUnits active. Empty → skip probe (always ok).
        probes = concatStringsSep " && "
          (map (u: "systemctl is-active --quiet --wait ${escapeShellArg u}") cfg.criticalUnits);
        timeout = toString cfg.healthCheckTimeout;
        hasUnits = cfg.criticalUnits != [ ];
      in ''
        set -u
        [ -f "${pendingFile}" ] || { echo "nixtache-apply: no pending system — nothing to do"; exit 0; }
        P=$(cat "${pendingFile}")
        # Capture the current (pre-apply) store path so we can revert on failure.
        prev=$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)

        rollback() {
          rm -f "${pendingFile}"
          if [ -n "$prev" ] && [ -e "$prev" ]; then
            echo "nixtache-apply: reverting system profile to $prev" >&2
            nix-env -p /nix/var/nix/profiles/system --set "$prev"
            # Re-activate the PRE-APPLY closure. NOT /run/current-system: after
            # a successful switch it already points at the new (broken) system,
            # which would re-activate the failure we are rolling back from.
            "$prev/bin/switch-to-configuration" switch \
              || echo "nixtache-apply: rollback switch failed — profile reverted; reboot to complete the rollback" >&2
          fi
        }

        # 1) set system profile + activate
        if ! nix-env -p /nix/var/nix/profiles/system --set "$P"; then
          echo "nixtache-apply: nix-env --set failed" >&2; rollback; exit 1
        fi
        if ! "$P/bin/switch-to-configuration" switch; then
          echo "nixtache-apply: switch-to-configuration failed" >&2; rollback; exit 1
        fi

        ${
          optionalString hasUnits ''
            # 2) Tier-1 probe: criticalUnits must come up within the window.
            deadline=$(( $(date +%s) + ${timeout} ))
            ok=0
            while [ "$(date +%s)" -lt "$deadline" ]; do
              if ${probes}; then ok=1; break; fi
              sleep 5
            done
            if [ "$ok" != 1 ]; then
              echo "nixtache-apply: criticalUnits not active within ${timeout}s — rolling back" >&2
              rollback
              exit 1
            fi
          ''
        }

        rm -f "${pendingFile}"
        echo "nixtache-apply: activated $P"
      '';
    };

    # --- the dry-apply unit (root) -------------------------------------------
    # PR-preview counterpart of nixtache-apply.service: runs
    # `switch-to-configuration dry-activate` on the staged closure — diff only,
    # ZERO mutation (no profile set, no unit changes). Separate unit (not a flag
    # on nixtache-apply.service) so polkit authorizes a distinct, strictly
    # read-only trigger; separate pointer (`pending-dry`) so a dry run and a
    # real activation never consume each other's signal. Replaces the legacy
    # `nixos-rebuild dry-activate --target-host --use-remote-sudo` action branch
    # which required sudo the deploy user must not have.
    systemd.services.nixtache-apply-dry = {
      description = "nixtache direct-deploy: dry-activate a staged system closure (diff, no mutation)";
      path = with pkgs; [ systemd nix coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -u
        [ -f "${pendingDryFile}" ] || { echo "nixtache-apply-dry: no pending dry-run — nothing to do"; exit 0; }
        P=$(cat "${pendingDryFile}")
        if [ ! -e "$P" ]; then
          echo "nixtache-apply-dry: staged closure $P not present in the store — push it first (nix copy)" >&2
          rm -f "${pendingDryFile}"
          exit 1
        fi
        # dry-activate: "would activate" — MUST NOT touch the system profile,
        # /run/current-system, or any unit state. (The restore below guards the
        # current-system symlink in case a future switch-to-configuration
        # repoints it in dry mode — observed NOT to, but cheap insurance.)
        prev_cur=$(readlink -f /run/current-system 2>/dev/null || true)
        "$P/bin/switch-to-configuration" dry-activate
        rc=$?
        if [ -n "$prev_cur" ] && [ -e "$prev_cur" ] \
            && [ "$(readlink -f /run/current-system 2>/dev/null || true)" != "$prev_cur" ]; then
          ln -sfn "$prev_cur" /run/current-system
          echo "nixtache-apply-dry: restored /run/current-system (dry-activate repointed it)" >&2
        fi
        rm -f "${pendingDryFile}"
        if [ "$rc" -ne 0 ]; then
          echo "nixtache-apply-dry: dry-activate exited $rc (diff generation failed — nothing was mutated)" >&2
          exit "$rc"
        fi
        echo "nixtache-apply-dry: dry-run complete for $P (no mutation)"
      '';
    };

    # --- polkit: deploy user may start ONLY the two apply units --------------
    # Least-privilege: the deploy user can trigger the apply units (which run as
    # root and do ALL the privileged work in a fixed, audited path) but can
    # start/stop nothing else. `verb == "start"` only — no stop/restart/reload.
    environment.etc."polkit-1/rules.d/49-nixtache-deploy.rules".text = ''
      // Generated by services.nixtache.deploy-target — authorize the deploy
      // user to start the apply units. Do not edit; managed by NixOS.
      polkit.addRule(function(action, subject) {
          if (action.id === "org.freedesktop.systemd1.manage-units"
              && (action.lookup("unit") === "nixtache-apply.service"
                  || action.lookup("unit") === "nixtache-apply-dry.service")
              && action.lookup("verb") === "start"
              && subject.user === "${duName}") {
              return polkit.Result.YES;
          }
      });
    '';
  };
}

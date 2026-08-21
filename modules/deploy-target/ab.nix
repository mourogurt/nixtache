# Target-side half of `method = "ab-image"` (Batch E).
#
# Imported by every ab-image target (on top of the base `deploy-target`
# module). Two responsibilities:
#   1. least-privilege: extend the deploy user's polkit authorization so it may
#      `start` the two ab-image units (`nixtache-ab-apply.service` for the
#      runner-host self-update gating path; `systemd-sysupdate.service` for
#      remote targets) — verb=start only, nothing else;
#   2. (runner-host only, `ab.gating = true`) the idle-gated apply: a
#      `systemd.path` watching for a staged-image signal (`ab-pending`) that
#      starts `nixtache-ab-apply.service`, which waits for ALL nixtache runners
#      on this host to report idle (Forgejo `/actions/runners` API) before
#      triggering `systemd-sysupdate` — so a self-update reboot never interrupts
#      a running CI job.
#
# The actual A/B slot write + reboot is done by `systemd-sysupdate` (enabled by
# the consumer; the image/transfer config is consumer-side per
# doc/specs/direct-deploy/06-ab-image.md). This module only GATES when it fires.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.deploy-target;
  ab = cfg.ab;
  du = cfg.deployUser;
  duName = if du != null then du.name else "nixos-deploy";

  stateDir = "/var/lib/nixtache";
  pendingFile = "${stateDir}/ab-pending";
in
{
  options.services.nixtache.deploy-target.ab = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this machine receives updates as A/B images via
        `systemd-sysupdate` (its `method` in the runner deploy map is
        `ab-image`). When set, the module extends the deploy user's polkit
        authorization to start the ab-image apply units. The consumer MUST
        separately enable `systemd.sysupdate` + `boot.loader.systemd-boot.bootCounting`
        (asserted below) and provide the image/repart/transfer config
        (doc/specs/direct-deploy/06-ab-image.md §1–6).
      '';
    };

    gating = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Idle-gate the self-update reboot. Set to `true` ONLY on the runner host
        (the machine whose live-switch would restart the runner container — the
        chicken-and-egg case). Provisions `nixtache-ab-apply.{path,service}`:
        when a new image is staged, the service waits for all nixtache runners
        on this host to report `busy=false` (Forgejo API) within
        `idleWaitTimeout` before triggering `systemd-sysupdate` — so a
        self-update never interrupts a running CI job. `false` (remote targets):
        sysupdate applies by its own timer / on SSH trigger, no idle wait.
      '';
    };

    idleWaitTimeout = mkOption {
      type = types.ints.positive;
      default = 1800;
      description = ''
        Seconds the gating unit waits for all nixtache runners to report idle
        before applying the self-update. Only meaningful when `gating = true`.
        Default 1800s (30 min). After the window, behaviour is governed by
        `forceAfterTimeout`.
      '';
    };

    forceAfterTimeout = mkOption {
      type = types.bool;
      default = false;
      description = ''
        What the gating unit does if runners are still busy when
        `idleWaitTimeout` elapses. `false` (default): leave the image pending
        and try again later (never interrupt a job). `true`: apply the update
        anyway (reboot even with running jobs — use only if freshness beats job
        continuity on this host).
      '';
    };

    forgejoApiTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a Forgejo API token with `read:actions` scope, used by the
        gating unit to poll `/api/v1/actions/runners` for busy state. Required
        when `gating = true` (asserted). Supplied by the consumer (sops/agenix/
        systemd). `null` on non-gating targets.
      '';
    };

    forgejoPort = mkOption {
      type = types.port;
      # Inherit the runner module's port when it is co-imported (the production
      # runner host runs both modules); standalone deploy-target hosts fall back
      # to 3000 and can override explicitly.
      default = config.services.nixtache.runner.forgejoPort or 3000;
      defaultText = literalExpression "config.services.nixtache.runner.forgejoPort or 3000";
      description = ''
        Port on localhost where the gating unit reaches the Forgejo API
        (`/api/v1/actions/runners`) to poll runner busy state. Only meaningful
        when `gating = true`. Defaults to
        `services.nixtache.runner.forgejoPort` when the runner module is
        co-imported, else 3000.
      '';
    };
  };

  config = mkIf (cfg.enable && ab.enable) {
    assertions = [
      {
        assertion = config.systemd.sysupdate.enable or false;
        message = "services.nixtache.deploy-target.ab.enable = true requires systemd.sysupdate.enable = true on this target (configure the A/B image transfers — see doc/specs/direct-deploy/06-ab-image.md).";
      }
      {
        assertion = config.boot.loader.systemd-boot.bootCounting.enable or false;
        message = "services.nixtache.deploy-target.ab.enable = true requires boot.loader.systemd-boot.bootCounting.enable = true on this target (A/B rollback relies on Automatic Boot Assessment — see doc/specs/direct-deploy/06-ab-image.md §5).";
      }
      {
        assertion = !ab.gating || ab.forgejoApiTokenFile != null;
        message = "services.nixtache.deploy-target.ab.gating = true requires forgejoApiTokenFile (a Forgejo API token with read:actions scope, to poll runner idle state).";
      }
      # A/B image updates are a systemd-boot + UKI + boot-counting feature — grub
      # cannot do Automatic Boot Assessment or boot UKIs from the ESP. The default
      # below turns grub OFF; this assert catches a consumer who force-enables it
      # back on an ab target (silent breakage of the rollback path otherwise).
      {
        assertion = !config.boot.loader.grub.enable;
        message = "services.nixtache.deploy-target.ab.enable = true is incompatible with boot.loader.grub.enable = true. A/B image updates require systemd-boot (UKI + Automatic Boot Assessment); grub cannot boot-count UKIs. Leave grub at its module default (off) or switch the target to systemd-boot.";
      }
    ];

    # A/B = systemd-boot only (the bootCounting assert above already enforces the
    # systemd-boot side). mkDefault so ab-image / a consumer can still override
    # in edge cases; the assert above catches a forced-on misconfiguration.
    boot.loader.grub.enable = mkDefault false;


    # --- polkit: deploy user may start the two ab-image units ----------------
    # Separate rule file from the live `nixtache-apply.service` rule in
    # apply.nix (kept independent so a target can have ab-image without live,
    # and vice versa). verb=start only — no stop/restart/reload, no other units.
    security.polkit.enable = true;
    environment.etc."polkit-1/rules.d/49-nixtache-ab.rules".text = ''
      // Generated by services.nixtache.deploy-target.ab — authorize the deploy
      // user to start the ab-image apply units. Do not edit; managed by NixOS.
      polkit.addRule(function(action, subject) {
          if (action.id === "org.freedesktop.systemd1.manage-units"
              && action.lookup("verb") === "start"
              && subject.user === "${duName}"
              && (action.lookup("unit") === "systemd-sysupdate.service"
                  || action.lookup("unit") === "nixtache-ab-apply.service")) {
              return polkit.Result.YES;
          }
      });
    '';

    # --- idle-gated self-update apply (runner-host only, gating = true) -------
    # `nixtache-ab-apply.path` fires when CI signals a newly staged image
    # (`touch ab-pending`); the service then waits for runner idle (Forgejo API)
    # before triggering `systemd-sysupdate`, which writes the inactive slot and
    # reboots. boot-counting rolls a bad slot back automatically. The whole path
    # only exists on the runner host, so `config.services.nixtache.runner.*`
    # (the runner module) is present there.
    systemd.paths.nixtache-ab-apply = mkIf ab.gating {
      description = "Trigger nixtache-ab-apply when a new ab-image is staged";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathExists = pendingFile;
    };

    systemd.services.nixtache-ab-apply = mkIf ab.gating {
      description = "nixtache ab-image self-update: wait for runner idle, then trigger systemd-sysupdate";
      path = with pkgs; [ systemd curl jq coreutils ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [ "forgejo-api:${toString ab.forgejoApiTokenFile}" ];
      };
      # `ab.forgejoPort` keeps deploy-target self-contained: it defaults to the
      # runner module's port when that module is co-imported (the runner host),
      # so no cross-module config read happens here.
      script = let
        forgejoPort = toString ab.forgejoPort;
        idleWait = toString ab.idleWaitTimeout;
        force = if ab.forceAfterTimeout then "1" else "0";
      in ''
        set -uo pipefail
        [ -f "${pendingFile}" ] || { echo "nixtache-ab-apply: no pending image — nothing to do"; exit 0; }

        deadline=$(( $(date +%s) + ${idleWait} ))
        busy=1
        while [ "$(date +%s)" -lt "$deadline" ]; do
          busy=$(curl -sf -H "Authorization: token $(cat ''${CREDENTIALS_DIRECTORY}/forgejo-api)" \
                 http://localhost:${forgejoPort}/api/v1/actions/runners \
                 | jq '[.[] | select(.busy == true)] | length' 2>/dev/null || echo 1)
          [ "$busy" = "0" ] && break
          sleep 10
        done

        if [ "$busy" != "0" ]; then
          if [ "${force}" != "1" ]; then
            echo "nixtache-ab-apply: runners still busy after ${idleWait}s, forceAfterTimeout=false — leaving image pending"; exit 0
          fi
          echo "nixtache-ab-apply: runners still busy, forceAfterTimeout=true — applying anyway"
        fi

        echo "nixtache-ab-apply: runners idle — triggering systemd-sysupdate (writes inactive slot, then reboots)"
        rm -f "${pendingFile}"
        systemctl start systemd-sysupdate.service
      '';
    };
  };
}

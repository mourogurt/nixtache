# Tier-0 boot-time health-check (the `nixtache-health-check.service` oneshot).
#
# Generated from `criticalUnits`: a oneshot that, in the window
# `healthCheckTimeout`, polls `systemctl is-active --wait <unit>` for each
# critical unit and exits 0 once all are active. Ordered Before= and
# RequiredBy= `boot-complete.target`, so a failure (any critical unit not active
# in time) keeps boot-complete unreached → no `systemd-bless-boot` blessing →
# with bootCounting enabled (consumer-scope, N1) the generation rolls back on
# the next boot.
#
# `RequiredBy` (not `WantedBy`) makes the gating strong: boot-complete cannot
# reach "active" while this service is failed. Without bootCounting, Tier-0
# merely withholds blessing; the live Tier-1 (deploy-rs, Batch C) or a manual
# `nixos-rebuild --rollback` is then the safety net.
#
# See doc/specs/direct-deploy/05-rollback.md Tier-0.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.deploy-target;
in
{
  config = mkIf (cfg.enable && cfg.criticalUnits != [ ]) {
    systemd.services.nixtache-health-check = {
      description = "Gate boot-complete.target on nixtache criticalUnits being active";
      path = [ pkgs.systemd ];
      serviceConfig.Type = "oneshot";

      # Strong gating: boot-complete.target Requires + runs After this service.
      # If this fails, boot-complete never reaches "active" → no bless.
      before = [ "boot-complete.target" ];
      requiredBy = [ "boot-complete.target" ];

      script = let
        # Join per-unit probes with `&&` so the chain exits 0 only when ALL are
        # active. escapeShellArg defends against unit names with shell
        # metacharacters (unit names are normally tame, but defence in depth).
        probes = concatStringsSep " && "
          (map (u: "systemctl is-active --quiet --wait ${escapeShellArg u}") cfg.criticalUnits);
        timeout = toString cfg.healthCheckTimeout;
      in ''
        deadline=$(( $(date +%s) + ${timeout} ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          if ${probes}; then
            exit 0
          fi
          sleep 5
        done
        echo "nixtache-health-check: criticalUnits not all active within ${timeout}s — boot not blessed" >&2
        exit 1
      '';
    };
  };
}

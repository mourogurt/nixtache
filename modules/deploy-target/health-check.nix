# Tier-0 boot-time health-check (the `nixtache-health-check.service` oneshot).
#
# Generated from `criticalUnits`: a oneshot that, in the window
# `healthCheckTimeout`, polls `systemctl is-active <unit>` for each
# critical unit and exits 0 once all are active. Ordered Before= and
# RequiredBy= `boot-complete.target`, so a failure (any critical unit not active
# in time) keeps boot-complete unreached → no `systemd-bless-boot` blessing →
# with bootCounting enabled (consumer scope) the generation rolls back on
# the next boot.
#
# `RequiredBy` (not `WantedBy`) makes the gating strong: boot-complete cannot
# reach "active" while this service is failed. Without bootCounting, Tier-0
# merely withholds blessing; the live Tier-1 (`nixtache-apply.service`) or a
# manual `nixos-rebuild --rollback` is then the safety net.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.deploy-target;

  # bootCounting turns Tier-0's withheld blessing into an actual generation
  # rollback on the next boot. Warn when it is applicable but off — without
  # the counter Tier-0 only logs and never rolls back. GRUB users can't
  # enable it (systemd-boot only); no warning for them.
  bootCountingOff =
    cfg.criticalUnits != [ ]
    && (config.boot.loader.systemd-boot.enable or false)
    && !(config.boot.loader.systemd-boot.bootCounting.enable or false);
in
{
  config = mkMerge [
    (mkIf (cfg.enable && cfg.criticalUnits != [ ]) {
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
          # active. NO --wait: it blocks indefinitely on a unit stuck in
          # "activating", defeating the deadline loop (the service — and
          # boot-complete — would hang forever). The loop IS the wait.
          # escapeShellArg defends against unit names with shell
          # metacharacters (unit names are normally tame, but defence in depth).
          probes = concatStringsSep " && "
            (map (u: "systemctl is-active --quiet ${escapeShellArg u}") cfg.criticalUnits);
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
    })

    (mkIf (cfg.enable && bootCountingOff) {
      warnings = [
        "services.nixtache.deploy-target: criticalUnits is set but boot.loader.systemd-boot.bootCounting.enable is off — Tier-0 will only withhold the boot blessing, it cannot roll the generation back. Enable bootCounting for boot-time rollback (systemd-boot targets only)."
      ];
    })
  ];
}

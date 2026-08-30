# Options for the receiving (target-side) module `nixosModules.deploy-target`.
#
# Imported by EVERY target machine. Owns:
#   - `criticalUnits` — the systemd units that MUST be active after activation
#     for the boot to be blessed (Tier-0) and for the apply unit's Tier-1 probe
#     to confirm activation (the same list feeds both). AmneziaWG is the
#     canonical universal entry; each target adds its own (forgejo + container
#     on the nixtache host, etc.).
#   - `healthCheckTimeout` — the window (seconds) both tiers wait for
#     criticalUnits.
#   - `deployUser` — the account the runner authenticates as; provisioned with
#     least-privilege: SSH key + membership in `nixtache-deploy` group (write to
#     the apply pointer dir) + polkit authorization to start
#     `nixtache-apply.service`. NO sudo/doas/run0 — activation is done by the
#     root-owned apply unit, triggered via polkit (see apply.nix).
#
# This module is INDEPENDENT of the runner-side `deploy.targets` map (Batch A):
# `criticalUnits`/`healthCheckTimeout` live here on the target, while the map
# lives on the runner host.
#
# See doc/specs/direct-deploy/04-consumer-wiring.md and 05-rollback.md.
{ lib, ... }:

with lib;

{
  options.services.nixtache.deploy-target = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether this machine is a direct-deploy target. Disabling turns off the
        `nixtache-apply.service` (live activation), the Tier-0 health-check
        oneshot, and deploy-user provisioning.
      '';
    };

    criticalUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "amneziawg-wg0.service" "forgejo.service" ];
      description = ''
        systemd units that MUST be active for an activation to be considered
        healthy. Feeds BOTH rollback tiers:

        - Tier-0 (boot-time): the `nixtache-health-check.service` oneshot waits
          for each of these (window `healthCheckTimeout`) before
          `boot-complete.target` is reached; failure means no boot blessing
          (with bootCounting enabled, the generation rolls back on next boot).
        - Tier-1 (live): the `nixtache-apply.service` probes these right after
          `switch-to-configuration switch` and rolls the profile back on failure
          (see apply.nix).

        AmneziaWG (`amneziawg-wg0.service`) is the canonical universal entry;
        add per-target services here (e.g. `forgejo.service`,
        `nixos-container@runner.service` on the nixtache host).
      '';
    };

    healthCheckTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = ''
        Seconds both tiers wait for all `criticalUnits` to become active before
        declaring the activation/boot unhealthy. Default 300s (5 min) — some
        machines boot/switch slowly. Per-target tunable.
      '';
    };

    deployUser = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            default = "nixos-deploy";
            description = "Deploy user account name on this target (the runner SSHes in as this).";
          };
          authorizedKey = mkOption {
            type = types.str;
            description = ''
              SSH public key line for the deploy user (matches the private key
              the runner holds for this target). Set by the consumer.
            '';
          };
          autoProvision = mkOption {
            type = types.bool;
            default = true;
            description = ''
              `true` (default): the module creates `users.users.<name>` as a
              SYSTEM user (`isSystemUser`, uid < 1000 — invisible in SDDM/Plasma
              login screens), installs the `authorizedKey` (with the SSH gate
              prefix, see `sshGate`), and adds it to the `nixtache-deploy` group
              (write access to the apply pointer dir). `false`: the consumer
              manages the user/key themselves; the module still grants the
              polkit + group membership for activation (permissions are always
              the module's job), asserts the user exists, and warns when the
              hand-managed user is a normal (display-manager-visible) user.
            '';
          };
          sshGate = mkOption {
            type = types.enum [ "gate" "restrict" "none" ];
            default = "gate";
            description = ''
              How the auto-provisioned authorized key restricts the SSH session:

              - `"gate"` (default): the key line gets a
                `restrict,command=<nixtache-ssh-gate>` prefix. The gate allows
                exactly the deploy protocol's remote commands (`nix-store
                --serve` for `nix copy --to`, the apply-unit trigger,
                `systemd-sysupdate` triggers, the `true` probe) and rejects
                anything else — no shell, no port forwarding, no agent/X11
                (`restrict`).
              - `"restrict"`: only the `restrict` prefix (no command gate) —
                escape hatch for protocol drift between the action version and
                this module: commands run unrestricted-minus-features until
                both sides are updated.
              - `"none"`: plain key line, no options (legacy behavior).

              Only meaningful with `autoProvision = true` (otherwise the key
              line is the consumer's; the module emits a warning suggesting the
              ready-made gate prefix).
            '';
          };
        };
      });
      default = null;
      description = ''
        The deploy user account the runner authenticates as on this target. The
        module provisions it (when `autoProvision = true`) with least-privilege
        — SSH key + `nixtache-deploy` group + polkit authorization to start
        the root-owned `nixtache-apply.service`. NO sudo/doas/run0: the runner
        only copies the closure (`nix copy --to`), drops a pointer file, and
        triggers the apply unit; all root work happens inside the unit. `null`
        = no deploy user provisioned (the consumer sets up auth out-of-band).

        The account is added to `nix.settings.trusted-users` unconditionally:
        `nix copy --to ssh://…` pushes locally-built (unsigned) closures, and
        the nix daemon only imports those for trusted users — this is a
        protocol requirement of the live path, not an optional privilege.
      '';
    };
  };
}

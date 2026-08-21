# Provisioning of the deploy user (SSH access + apply-trigger authorization).
#
# The runner authenticates to the target as this user to do exactly TWO things:
#   1. `nix copy --to ssh://<user>@<host>` — push the built closure into the
#      target's nix store. The store is served as this user, so the nix-daemon
#      must trust it to import unsigned paths (`nixTrust` adds it to
#      `nix.settings.trusted-users`);
#   2. drop a pointer file at `/var/lib/nixtache/pending-system` and
#      `systemctl start nixtache-apply.service` — trigger the root-owned apply
#      unit. File write is via `nixtache-deploy` group membership; the unit
#      start is via polkit (wired in apply.nix).
#
# That is the ENTIRE surface — no sudo / doas / sudo-rs / run0 anywhere. All
# root work (set profile, switch-to-configuration, probe, rollback) happens
# inside `nixtache-apply.service`, started by polkit. This is why the module is
# escalation-tool-agnostic: there is no escalation tool to be agnostic about.
#
# `autoProvision = true`: module creates the user + key + group membership.
# `autoProvision = false`: consumer owns the user/key; module still adds the
# group membership (needed for the pointer-dir write) and asserts the user
# exists.
#
# See doc/specs/direct-deploy/04-consumer-wiring.md §B.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.deploy-target;
  du = cfg.deployUser;
in
{
  config = mkIf (cfg.enable && du != null) {
    # The deploy user must be in `nixtache-deploy` to write the apply pointer
    # file (apply.nix owns the group + dir). autoProvision creates both the user
    # and the membership; otherwise only the membership (user is consumer's).
    users.groups.nixtache-deploy = { };

    # The deploy user must be in `nixtache-deploy` to write the apply pointer
    # file (apply.nix owns the group + dir). mkMerge combines the two exclusive
    # branches into ONE definition of users.users.<name> (Nix forbids two
    # dynamic-keyed assignments in one module).
    users.users.${du.name} = mkMerge [
      (mkIf du.autoProvision {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [ du.authorizedKey ];
        extraGroups = [ "nixtache-deploy" ];
      })
      # autoProvision = false: consumer manages the user; still join the group
      # (so the pointer dir is writable). extraGroups is a list — module merge
      # concatenates this with the consumer's own groups.
      (mkIf (!du.autoProvision) {
        extraGroups = [ "nixtache-deploy" ];
      })
    ];

    # `nix copy --to ssh://` serves the store as the deploy user; the daemon
    # imports unsigned closure paths only for trusted users.
    nix.settings.trusted-users = mkIf du.nixTrust [ du.name ];

    assertions = mkIf (!du.autoProvision) [
      {
        assertion = config.users.users ? ${du.name};
        message = ''
          services.nixtache.deploy-target.deployUser.autoProvision = false but
          the user `${du.name}` does not exist on this target. Either create it
          yourself or set autoProvision = true.
        '';
      }
    ];
  };
}

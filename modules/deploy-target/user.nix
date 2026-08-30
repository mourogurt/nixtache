# Provisioning of the deploy user (SSH access + apply-trigger authorization).
#
# The runner authenticates to the target as this user to do exactly TWO things:
#   1. `nix copy --to ssh://<user>@<host>` — push the built closure into the
#      target's nix store. The store is served as this user, so the nix-daemon
#      must trust it to import unsigned, locally-built paths (trust is a
#      protocol requirement of the serve-write channel — see
#      nix.conf(5) `trusted-users` — and is therefore wired unconditionally
#      below, not behind an option);
#   2. drop a pointer file at `/var/lib/nixtache/pending-system` and
#      `systemctl start nixtache-apply.service` — trigger the root-owned apply
#      unit. File write is via `nixtache-deploy` group membership; the unit
#      start is via polkit (wired in apply.nix).
#
# That is the ENTIRE surface — no sudo / doas / sudo-rs / run0 anywhere. All
# root work (set profile, switch-to-configuration, probe, rollback) happens
# inside `nixtache-apply.service`, started by polkit.
#
# The account is a SYSTEM user (`isSystemUser`, uid < 1000): it must never
# show up in graphical login screens (SDDM/Plasma list normal users only).
# The SSH session is gated by `nixtache-ssh-gate` (deployUser.sshGate):
# an authorized_keys `restrict,command=…` prefix that whitelists exactly the
# deploy protocol's remote commands — see the gate script below.
#
# `autoProvision = true`: module creates the user + gated key + group
# membership. `autoProvision = false`: consumer owns the user/key; module
# still adds the group membership (needed for the pointer-dir write), asserts
# the user exists, and warns about normal-user visibility + the recommended
# gate prefix for the hand-managed key.
#
# See doc/specs/direct-deploy/04-consumer-wiring.md §B.
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

  # The SSH command gate: allows exactly the remote commands the
  # deploy-target action issues, rejects everything else. Runs as the
  # ForcedCommand of the deploy key (`restrict,command=<this script>` in
  # authorized_keys) — a store path, so it is safe to embed in the key line.
  sshGate = pkgs.writeShellScript "nixtache-ssh-gate" ''
    set -u
    cmd="''${SSH_ORIGINAL_COMMAND:-}"

    allow() {
      # Re-exec the validated command through the login shell (the exact
      # string was matched above — no injection surface).
      exec ${pkgs.runtimeShell} -c "$cmd"
    }

    # probe (R5): `ssh … true`
    if [ "$cmd" = "true" ]; then allow; fi

    # `nix copy --to ssh://` serves the store: `nix-store --serve [--write] …`
    case "$cmd" in
      "nix-store --serve"*) allow ;;
    esac

    # live apply trigger (action: echo '$P' > pointer && systemctl start …).
    # The regex lives in a variable — [[ =~ ]] parsing of inline escaped
    # metacharacters is brittle across bash versions.
    trigger_re="^echo '/nix/store/[^']+' > /var/lib/nixtache/pending-system && systemctl start nixtache-apply\\.service$"
    if [[ "$cmd" =~ $trigger_re ]]; then
      allow
    fi

    # dry-apply trigger (action dry-activate branch: pointer pending-dry).
    dry_re="^echo '/nix/store/[^']+' > /var/lib/nixtache/pending-dry && systemctl start nixtache-apply-dry\\.service$"
    if [[ "$cmd" =~ $dry_re ]]; then
      allow
    fi

    # local-self ab-image signal (action's _abImage local branch)
    if [ "$cmd" = "mkdir -p /var/lib/nixtache && touch /var/lib/nixtache/ab-pending && systemctl start nixtache-ab-apply.service" ]; then
      allow
    fi

    # remote ab-image triggers (update / update+reboot)
    case "$cmd" in
      "systemctl start systemd-sysupdate.service"|"systemctl start systemd-sysupdate-reboot.service") allow ;;
    esac

    echo "nixtache-ssh-gate: command not allowed by the nixtache deploy gate: $cmd" >&2
    exit 1
  '';

  gatePrefix = "restrict,command=\"${sshGate}\" ";
  keyLine =
    if du.sshGate == "gate" then gatePrefix + du.authorizedKey
    else if du.sshGate == "restrict" then "restrict ${du.authorizedKey}"
    else du.authorizedKey;
in
{
  config = mkIf (cfg.enable && du != null) {
    # The deploy user must be in `nixtache-deploy` to write the apply pointer
    # file (apply.nix owns the group + dir). autoProvision creates both the user
    # and the membership; otherwise only the membership (user is consumer's).
    users.groups.nixtache-deploy = { };

    users.users.${du.name} = mkMerge [
      (mkIf du.autoProvision {
        # SYSTEM account: invisible in display managers (SDDM & co. only list
        # normal users / uid >= 1000). It exists solely for the gated SSH
        # channel — no interactive login, no home in /home. useDefaultShell so
        # the ForcedCommand (`shell -c <gate>`) is runnable — nologin would
        # block even the gate.
        isSystemUser = true;
        useDefaultShell = true;
        home = "/var/lib/nixtache";
        createHome = false;
        group = "nixtache-deploy";
        openssh.authorizedKeys.keys = [ keyLine ];
        extraGroups = [ ];
      })
      # autoProvision = false: consumer manages the user; still join the group
      # (so the pointer dir is writable). extraGroups is a list — module merge
      # concatenates this with the consumer's own groups.
      (mkIf (!du.autoProvision) {
        extraGroups = [ "nixtache-deploy" ];
      })
    ];

    # `nix copy --to ssh://` serves the store as the deploy user; the daemon
    # imports unsigned closure paths only for trusted users (nix.conf(5)).
    # Protocol requirement — not optional, hence no toggle.
    nix.settings.trusted-users = [ du.name ];

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

    warnings =
      optional (!du.autoProvision && config.users.users ? ${du.name} && config.users.users.${du.name}.isNormalUser or false)
        "services.nixtache.deploy-target.deployUser: `${du.name}` is a normal user (isNormalUser) — it will be visible in graphical login screens (SDDM). Provision it as a system user (isSystemUser, uid < 1000) instead."
      ++ optional (!du.autoProvision && du.sshGate == "gate")
        "services.nixtache.deploy-target.deployUser: autoProvision = false — the module cannot gate the hand-managed key. Recommended authorized_keys line prefix: ${gatePrefix}";
  };
}

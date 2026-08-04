# SSH credentials for the runner: two independent bundles.
#
# `flakeSshCreds` gates private-flake-input fetch (`nix flake check` /
# `nix flake metadata`), `updateSshCreds` gates the update-flake workflow
# (push + commit signing). Each bundle, when set, is bind-mounted into the
# container and exposed to every `gitea-runner-*` service via a purpose-specific
# systemd `LoadCredential` (`flake_ssh_*` / `update_ssh_*`); the `ssh-setup`
# composite action picks the right pair via its `creds` input.
#
# The git SSH transport users (`*.user`) are exported to every job as
# `NIXTACHE_FLAKE_GIT_USER` / `NIXTACHE_UPDATE_GIT_USER` envs — those live in
# instances.nix alongside the other `runner.envs`.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;

  typesT = import ./types.nix { inherit lib; };

  flakeSsh = cfg.flakeSshCreds;
  updateSsh = cfg.updateSshCreds;
  flakeSshEnabled = flakeSsh != null;
  updateSshEnabled = updateSsh != null;
  anySsh = flakeSshEnabled || updateSshEnabled;

  # Each enabled instance receives the SSH LoadCredentials on its service.
  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;
in
{
  options.services.nixtache.runner = {
    # SSH credentials for fetching PRIVATE flake inputs (e.g. nixos-private)
    # during `nix flake check`. Optional: omit for public-input-only setups.
    # Exported to jobs as NIXTACHE_FLAKE_GIT_USER + a `flake_ssh_*`
    # LoadCredential that the ssh-setup action (creds: flake) reads.
    flakeSshCreds = mkOption {
      type = types.nullOr typesT.sshCredsType;
      default = null;
      description = ''
        SSH credentials for fetching private flake inputs in CI. When set,
        `nix flake check` / `nix flake metadata` can git+ssh-clone private
        inputs (e.g. `nixos-private`). null = no private-input auth (public
        inputs only).
      '';
    };

    # SSH credentials for the update-flake workflow (push lock-file commits +
    # sign them). Optional: when null, update-flake self-disables with a
    # warning. Exported as NIXTACHE_UPDATE_GIT_USER + `update_ssh_*`
    # LoadCredential (ssh-setup creds: update). Typically the same key files as
    # `flakeSshCreds`.
    updateSshCreds = mkOption {
      type = types.nullOr typesT.sshCredsType;
      default = null;
      description = ''
        SSH credentials for the update-flake workflow (push + commit signing).
        null = update-flake is disabled (its workflow detects the missing
        credential and no-ops with a warning). Typically points at the same
        key files as `flakeSshCreds`.
      '';
    };
  };

  config = mkIf cfg.enable {
    # One container literal: the SSH key bind-mounts + the per-service
    # LoadCredential wiring. Single use of the dynamic key
    # `${cfg.containerName}` (Nix forbids two path-assignments sharing a
    # dynamic prefix inside one literal).
    containers.${cfg.containerName} = {
      bindMounts = mkMerge [
        (optionalAttrs flakeSshEnabled {
          "flake-ssh-private-key" = {
            mountPoint = "/var/secrets/runner/flake_ssh_key";
            hostPath = flakeSsh.sshPrivateKey;
            isReadOnly = true;
          };
          "flake-ssh-public-key" = {
            mountPoint = "/var/secrets/runner/flake_ssh_key.pub";
            hostPath = flakeSsh.sshPublicKey;
            isReadOnly = true;
          };
        })
        (optionalAttrs updateSshEnabled {
          "update-ssh-private-key" = {
            mountPoint = "/var/secrets/runner/update_ssh_key";
            hostPath = updateSsh.sshPrivateKey;
            isReadOnly = true;
          };
          "update-ssh-public-key" = {
            mountPoint = "/var/secrets/runner/update_ssh_key.pub";
            hostPath = updateSsh.sshPublicKey;
            isReadOnly = true;
          };
        })
      ];

      config = { ... }: {
        systemd.services = mapAttrs'
          (iname: _:
            nameValuePair "gitea-runner-${iname}" (mkIf anySsh {
              # SSH credentials are loaded per purpose (flake / update), each
              # only when its bundle is configured. ssh-setup selects via its
              # `creds` input → $CREDENTIALS_DIRECTORY/<creds>_ssh_*.
              serviceConfig.LoadCredential =
                (optional flakeSshEnabled "flake_ssh_private:/var/secrets/runner/flake_ssh_key")
                ++ (optional flakeSshEnabled "flake_ssh_public:/var/secrets/runner/flake_ssh_key.pub")
                ++ (optional updateSshEnabled "update_ssh_private:/var/secrets/runner/update_ssh_key")
                ++ (optional updateSshEnabled "update_ssh_public:/var/secrets/runner/update_ssh_key.pub");
            }))
          enabledInstances;
      };
    };
  };
}

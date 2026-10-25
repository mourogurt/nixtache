# Direct-deploy target map: `services.nixtache.runner.deploy.targets`.
#
# Owns the `config → host → creds` map. Each target's attribute name MUST
# match the consumer's
# `nixosConfigurations.<name>` — the `deploy-target` action pairs configs and
# targets by that name. This module:
#
#   1. serializes the NON-secret subset of the map into the job env
#      `NIXTACHE_DEPLOY_TARGETS` (via the `_extraRunnerEnvs` aggregator owned by
#      instances.nix) — `{name, enable, host, sshUser, sshPort, method, system,
#      tags, timeout, extraOptions, minFreeBytes, hasKey}`;
#   2. bind-mounts each target's private key into the container at a fixed path
#      `/var/secrets/runner/deploy/<name>/id_ed25519` (and, when `sshPublicKey`
#      is set, the matching `.pub`) and exposes them to every
#      `forgejo-runner-*` service via `LoadCredential` (`deploy_ssh_<name>` /
#      `deploy_ssh_<name>.pub`), mirroring the `flake_ssh_*` / `update_ssh_*`
#      pattern in ssh.nix.
#
# Secret paths never leave the host eval: only `hasKey: bool` ships in the env.
# The map is the single source of truth for the job env; the `deploy-target`
# action reads it directly (V2 — no `deploy.nodes` flake output, no deploy-rs).
{
  config,
  lib,
  ...
}:

with lib;

let
  runnerCfg = config.services.nixtache.runner;
  cfg = runnerCfg.deploy;

  # Host-side computations (the inner container `config` can't see host
  # `services.nixtache.*`). Same pattern as ssh.nix / instances.nix.
  enabledInstances = filterAttrs (_: i: i.enable) runnerCfg.instances;

  # Per-target deploy key bind-mounts (only targets that actually have a key).
  targetsWithKey = filterAttrs (_: t: t.sshPrivateKey != null) cfg.targets;
  targetsWithPubKey = filterAttrs (_: t: t.sshPublicKey != null) cfg.targets;

  # LoadCredential entries — same set on every forgejo-runner-<name> service.
  deployLoadCreds =
    (mapAttrsToList
      (name: _: "deploy_ssh_${name}:/var/secrets/runner/deploy/${name}/id_ed25519")
      targetsWithKey)
    ++ (mapAttrsToList
      (name: _: "deploy_ssh_${name}.pub:/var/secrets/runner/deploy/${name}/id_ed25519.pub")
      targetsWithPubKey);
in
{
  options.services.nixtache.runner.deploy.targets = mkOption {
    type = types.attrsOf (import ./types.nix { inherit lib; }).deployTargetType;
    default = { };
    description = ''
      Direct-deploy target map. One attribute per machine this runner may deploy
      to; the attribute name MUST equal the consumer's
      `nixosConfigurations.<name>`. Each entry binds the config to a reachable
      host (`host`/`sshUser`/`sshPort`) and a credential (`sshPrivateKey`).

      The map is serialized (minus secret paths) into the job env
      `NIXTACHE_DEPLOY_TARGETS`, and the deploy keys are exposed to jobs via
      `LoadCredential`. Targets with `sshPrivateKey = null` or `enable = false`
      are skipped by the action (optionality by construction).

      See `doc/user_guide/deploy.md`.
    '';
  };

  config = mkIf runnerCfg.enable {
    # 1) Map → job env (empty map `{}` when no targets configured; the action
    #    treats `{}` as "no deploy targets" and no-ops). No secret paths leak —
    #    only `hasKey: bool` per target. `enable` and `extraOptions` MUST ship:
    #    the action's optionality filters read both.
    services.nixtache.runner._extraRunnerEnvs.NIXTACHE_DEPLOY_TARGETS =
      builtins.toJSON (mapAttrs (name: t: {
        inherit name;
        inherit (t)
          enable
          host
          sshUser
          sshPort
          method
          system
          tags
          timeout
          extraOptions
          minFreeBytes
          ;
        hasKey = t.sshPrivateKey != null;
      }) cfg.targets);

    # 2) Keys → container (bind-mount + per-service LoadCredential), mirroring
    #    ssh.nix. The inner `config` runs in the CONTAINER eval — it only uses
    #    host-side `let` bindings above, never host `config.*`.
    containers.${runnerCfg.containerName} = {
      bindMounts = (mapAttrs' (name: t:
        nameValuePair "deploy_ssh_${name}" {
          mountPoint = "/var/secrets/runner/deploy/${name}/id_ed25519";
          # `toString`: bindMounts.hostPath is string-typed; sshPrivateKey may be
          # a path literal (tests) or a string (real sops/agenix paths). Coerce
          # robustly — identity for strings.
          hostPath = toString t.sshPrivateKey;
          isReadOnly = true;
        }
      ) targetsWithKey) // (mapAttrs' (name: t:
        nameValuePair "deploy_ssh_${name}-pub" {
          mountPoint = "/var/secrets/runner/deploy/${name}/id_ed25519.pub";
          hostPath = toString t.sshPublicKey;
          isReadOnly = true;
        }
      ) targetsWithPubKey);

      config = { ... }: {
        systemd.services = mapAttrs' (iname: _:
          nameValuePair "forgejo-runner-${iname}" {
            serviceConfig.LoadCredential = mkIf (deployLoadCreds != [ ]) deployLoadCreds;
          }
        ) enabledInstances;
      };
    };
  };
}

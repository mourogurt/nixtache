# Runner instances + bot identity + per-job env aggregation.
#
# Owns `instances.<name>` (one `gitea-runner-<name>` per attr, each with its
# own registration token) and `bot.{name,email}` (the commit identity for
# CI-generated commits). Builds the in-container `services.gitea-actions-runner`
# map and aggregates the per-job `runner.envs` from values declared in other
# sub-modules:
#
#   - ssh.nix        → NIXTACHE_FLAKE_GIT_USER / NIXTACHE_UPDATE_GIT_USER
#   - bot (here)     → NIXTACHE_BOT_NAME / NIXTACHE_BOT_EMAIL
#   - sandbox.nix    → HAS_SANDBOX_CAP (mirrors enableSandbox 1:1)
#
# act_runner `runner.envs` is mode-agnostic (applies to host mode too, not just
# docker), so the envs reach every job step regardless of how it runs.
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

  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;
in
{
  options.services.nixtache.runner = {
    # Bot identity (Forgejo account) that owns CI-generated commits. Its KEY is
    # `updateSshCreds`; `name`/`email` are the commit author. Exported to jobs
    # as NIXTACHE_BOT_NAME / NIXTACHE_BOT_EMAIL.
    bot = {
      name = mkOption {
        type = types.str;
        default = "fbot";
        description = "Bot account name (commit `user.name`) for CI-generated commits.";
      };
      email = mkOption {
        type = types.str;
        default = "fbot@localhost";
        description = "Bot account email (commit `user.email`) for CI-generated commits.";
      };
    };

    # Runner instances. Each registers as a separate runner on `forgejoUrl`
    # with its own name/labels/tokenFile; all share the container's store,
    # (optional) SSH/bot keys, cache and nix settings. Add a second instance
    # (e.g. `test`) to get a dedicated runner for CI experiments routed by label.
    instances = mkOption {
      type = types.attrsOf typesT.instanceType;
      description = ''
        Runner instances to start inside the container. Each becomes a
        `gitea-runner-<name>` service and needs its own `tokenFile`
        (a Forgejo registration token). Example:

        ```
        instances = {
          default = { tokenFile = config.sops.secrets.runner-token-default.path; };
          test    = { labels = [ "nixos:test" ]; tokenFile = config.sops.secrets.runner-token-test.path; };
        };
        ```
      '';
    };
  };

  config = mkIf cfg.enable {
    # One container literal: per-instance token mounts + the
    # `services.gitea-actions-runner` map. Single use of the dynamic key
    # `${cfg.containerName}` (Nix forbids two path-assignments that share a
    # dynamic prefix inside the same literal).
    containers.${cfg.containerName} = {
      bindMounts = listToAttrs (mapAttrsToList
        (iname: i:
          nameValuePair "runner-token-${iname}" {
            mountPoint = "/var/secrets/runner/${iname}/token";
            hostPath = i.tokenFile;
            isReadOnly = true;
          })
        enabledInstances);

      config = { lib, ... }: {
      services.gitea-actions-runner = {
        package = cfg.package;
        # One instance per enabled entry; all share forgejoUrl, host packages,
        # timeouts and log level. Each gets its own token mount + registration.
        instances = mapAttrs (iname: i: {
          enable = true;
          name = i.name;
          url = cfg.forgejoUrl;
          tokenFile = "/var/secrets/runner/${iname}/token";
          labels = i.labels;
          settings = {
            runner = {
              timeout = cfg.runnerTimeout;
              shutdown_timeout = cfg.runnerTimeout;
              # Export SSH users + bot identity to every job step (act_runner
              # `runner.envs` — mode-agnostic, applies to host mode too).
              # `ssh-setup` picks the right pair via its `creds` input.
              # HAS_SANDBOX_CAP tells the reusable actions whether the daemon
              # can sandbox (1) or whether they must fall back to --no-sandbox
              # (0); mirrors `enableSandbox` 1:1.
              envs = {
                NIXTACHE_FLAKE_GIT_USER = lib.optionalString flakeSshEnabled flakeSsh.user;
                NIXTACHE_UPDATE_GIT_USER = lib.optionalString updateSshEnabled updateSsh.user;
                NIXTACHE_BOT_NAME = cfg.bot.name;
                NIXTACHE_BOT_EMAIL = cfg.bot.email;
                HAS_SANDBOX_CAP = if cfg.enableSandbox then "1" else "0";
              };
            };
            log = {
              level = cfg.logLevel;
              job_level = cfg.logLevel;
            };
          };
          hostPackages = cfg.hostPackages;
        }) enabledInstances;
      };
      };
    };
  };
}

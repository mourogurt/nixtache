# Runner instances + bot identity + per-job env aggregation.
#
# Owns `instances.<name>` (one `forgejo-runner-<name>` service per attr, each
# its own Forgejo registration — a uuid + token pair obtained from Forgejo
# when the registration is created; runners no longer self-register) and
# `bot.{name,email}` (the commit identity for CI-generated commits). Builds
# the in-container `services.forgejo-runner` map and aggregates the per-job
# `runner.envs` from values declared in other sub-modules:
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
    # Internal aggregator: sub-modules (e.g. `deploy.nix`) append per-job env
    # keys here; this module folds them into `runner.envs` below alongside the
    # hardcoded `NIXTACHE_*` / `HAS_SANDBOX_CAP` keys. Lets a sub-module export
    # its own job-visible variable (like `NIXTACHE_DEPLOY_TARGETS`) without
    # touching this file and without duplicating the envs plumbing. Internal —
    # not part of the public contract; consumers set `deploy.targets`, not this.
    _extraRunnerEnvs = mkOption {
      type = types.attrsOf types.str;
      default = { };
      internal = true;
      description = ''
        Internal: extra env keys merged into act_runner `runner.envs` from
        sibling sub-modules. Not a public option — set `deploy.targets` etc.
        instead.
      '';
    };

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

    # Runner instances. Each is its own Forgejo registration (`uuid` +
    # `tokenFile` with the bare runner token) with its own labels; all share
    # the container's store, (optional) SSH/bot keys, cache and nix settings.
    # Add a second instance (e.g. `test`) to get a dedicated runner for CI
    # experiments routed by label. The runner name is fixed in Forgejo when
    # the registration is created — not configured here.
    instances = mkOption {
      type = types.attrsOf typesT.instanceType;
      description = ''
        Runner instances to start inside the container. Each becomes a
        `forgejo-runner-<name>` service and needs its own Forgejo registration
        (`uuid` + `tokenFile` with the bare runner token). Example:

        ```
        instances = {
          default = { uuid = "c9e50be9-..."; tokenFile = config.sops.secrets.runner-token-default.path; };
          test    = { uuid = "1c3a3b5b-..."; labels = [ "nixos:test" ]; tokenFile = config.sops.secrets.runner-token-test.path; };
        };
        ```
      '';
    };
  };

  config = mkIf cfg.enable {
    # One container literal: per-instance token mounts + the
    # `services.forgejo-runner` map. Single use of the dynamic key
    # `${cfg.containerName}` (Nix forbids two path-assignments that share a
    # dynamic prefix inside the same literal).
    containers.${cfg.containerName} = {
      bindMounts = listToAttrs (mapAttrsToList
        (iname: i:
          nameValuePair "runner-token-${iname}" {
            mountPoint = "/var/secrets/runner/${iname}/token";
            # `toString`: bindMounts.hostPath is string-typed; tokenFile may be
            # a path literal (tests) or a string (real sops/agenix paths).
            # Coerce robustly — identity for strings.
            hostPath = toString i.tokenFile;
            isReadOnly = true;
          })
        enabledInstances);

      config = { lib, ... }: {
      # forgejo-runner-<name> is a DynamicUser unit whose user is NSS-visible
      # under the unit's own name (nss-systemd). Dynamic users are NOT in the
      # `users` group, so the base config's `@users` entry does not cover
      # them — list each instance's user explicitly, or host-mode jobs lose
      # trusted-client status (no substituters, no `nix copy --to` for direct
      # deploy).
      nix.settings.trusted-users = mapAttrsToList
        (iname: _: "forgejo-runner-${iname}")
        enabledInstances;

      services.forgejo-runner = {
        package = cfg.package;
        # One instance per enabled entry; all share forgejoUrl, host packages,
        # timeouts and log level. Each instance is its own registration:
        # connection `default` carries the shared URL + the per-instance uuid,
        # and the bare runner token is read at service start from the
        # read-only bind mount via the upstream module's secrets templating
        # (token_url → systemd LoadCredential). The runner name is fixed in
        # Forgejo at registration time and is not configured here.
        instances = mapAttrs (iname: i: {
          enable = true;
          settings = {
            server.connections.default = {
              url = cfg.forgejoUrl;
              uuid = i.uuid;
            };
            runner = {
              labels = i.labels;
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
              } // cfg._extraRunnerEnvs;
            };
            log = {
              level = cfg.logLevel;
              job_level = cfg.logLevel;
            };
          };
          secrets.server.connections.default.token_url =
            "/var/secrets/runner/${iname}/token";
          hostPackages = cfg.hostPackages;
        }) enabledInstances;
      };
      };
    };
  };
}

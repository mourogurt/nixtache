# nixtache secrets abstraction.
#
# Model: the END RESULT is a uniform namespace of materialised secret paths
# (`services.nixtache.secrets.vars.<name>`), which nixtache modules and the
# consumer's own config read from. HOW those paths get populated is the job of
# PROVIDERS — and any combination of providers may be active at once.
#
# Planned providers (this file declares the contract surface; concrete
# implementations land incrementally — keep it minimal for now, just reflect
# that more are coming):
#
#   ssh     Secrets fetched via a git+ssh private flake (the current
#           `nixos-private` pattern: its nixosModules expose `*_secrets` as
#           module args) or supplied directly as SSH key file paths.
#   forgejo Secrets injected as Forgejo CI variables
#           (`${{ secrets.X }}`) at the workflow level.
#   vault   HashiCorp Vault via vault-agent (static file destination) or
#           `numtide/systemd-vaultd` (`$CREDENTIALS_DIRECTORY/<key>`).
#           Intended as the PRIMARY provider going forward.
#   systemd Host-managed `systemd` LoadCredential / credentials dir.
#
# Today the runner module (modules/runner/) consumes paths via its own
# `services.nixtache.runner.*` options (the stable direct contract). The
# `vars` namespace is the target providers write into; future runner wiring
# will let it read from `vars` instead of (or alongside) its direct options.
# Consumers can already populate `vars` manually for their own cross-module
# secret references.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.secrets;
in
{
  options.services.nixtache.secrets = {
    # The uniform "end result": logical name → materialised secret path on the
    # host. Populated by providers (mkMerge); consumed by nixtache modules and
    # the consumer's own config. Internal on purpose — write to it via a
    # provider or a direct consumer-side assignment.
    vars = mkOption {
      type = types.attrsOf types.path;
      default = { };
      internal = true;
      description = ''
        Materialised secret paths — the uniform end result every nixtache
        consumer reads from. Each entry is `<logical-name> = /run/.../path`.
        Populated by the enabled `providers` (mkMerge); may also be assigned
        directly by the consumer for cross-module secret references.

        Do not reference these paths in `config` unless the corresponding
        provider is enabled — they are only materialised when a provider is.
      '';
    };

    # Extensible provider registry. Each provider, when enabled, contributes
    # entries to `vars`. Multiple providers may be active simultaneously
    # (e.g. ssh for git+ssh-fetched values + vault for runtime-pulled ones +
    # forgejo for workflow-level vars). Modelled as a freeform submodule so a
    # new provider can carry whatever keys it needs without touching this
    # registry's type.
    providers = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether this provider is active. When true, the provider's module
              (loaded separately by the consumer or by a future nixtache
              bundle) populates `services.nixtache.secrets.vars`.
            '';
          };
          settings = mkOption {
            type = types.attrs;
            default = { };
            description = ''
              Provider-specific settings (endpoint, mapping, delivery mode,
              …). Shape depends on the provider; see the provider's own docs.
            '';
          };
        };
      });
      default = { };
      description = ''
        Secret providers — how entries of `services.nixtache.secrets.vars` are
        materialised. Any combination of providers may be active at once.

        Planned providers (each ships as its own nixtache sub-module):

        - `ssh` — secrets from a git+ssh-fetched private flake (the
          `nixos-private` pattern: `*_secrets` module args) or direct SSH key
          file paths. The supplementary provider.
        - `forgejo` — Forgejo CI variables (`''${{ secrets.X }}`), workflow
          level.
        - `vault` — HashiCorp Vault via `vault-agent` (static file) or
          `systemd-vaultd` (`$CREDENTIALS_DIRECTORY/<key>`). The intended
          PRIMARY provider.
        - `systemd` — host-managed `systemd` LoadCredential / credentials dir.

        Adding a provider is purely additive: it only appends to `vars`, so
        existing providers and direct `vars` assignments keep working.
      '';
    };
  };
}

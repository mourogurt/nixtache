# Binary cache: nix-serve inside the container + nginx vhost on the host.
#
# Owns `cache.{enable,domain,port,package}` and `secrets.cachePrivateKey`.
# The store-related amendments to `nix-serve` (BindPaths + custom-daemon dep)
# live in store.nix — they merge onto the service declared here.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.runner;
in
{
  options.services.nixtache.runner = {
    # --- Binary cache -------------------------------------------------------
    cache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to run nix-serve and expose it via nginx.";
      };

      domain = mkOption {
        type = types.str;
        example = "bincache.example.com";
        description = "Public domain for the binary cache nginx virtual host.";
      };

      port = mkOption {
        type = types.port;
        example = 7125;
        description = "Local port nix-serve listens on (proxied by nginx).";
      };

      package = mkOption {
        type = types.package;
        # nix-serve (Perl, tracks CppNix) serves content-addressed
        # realisations; nix-serve-ng (the Lix rewrite) does not know CA
        # derivations, which the relocated-store modes rely on.
        default = pkgs.nix-serve;
        defaultText = lib.literalExpression "pkgs.nix-serve";
        description = "nix-serve package to use.";
      };
    };

    # --- Secrets (path-based, supplied by the consumer) -------------------
    # NOTE: the registration token is per-instance (`instances.<name>.tokenFile`),
    # not global. SSH creds live in `flakeSshCreds` / `updateSshCreds` (ssh.nix).
    # The consumer may instead populate these via a nixtache secrets provider
    # (modules/secrets.nix); the path-based options here remain the stable
    # direct contract.
    secrets = {
      cachePrivateKey = mkOption {
        type = types.path;
        description = "Binary cache signing key file (used by nix-serve).";
      };
    };
  };

  config = mkIf cfg.enable {
    # One container literal: the cache-key mount + the in-container nix-serve.
    # Single use of the dynamic key `${cfg.containerName}` (Nix forbids two
    # path-assignments sharing a dynamic prefix inside one literal).
    containers.${cfg.containerName} = {
      bindMounts."cache-private-key" = {
        mountPoint = "/var/secrets/runner/cache-private-key.pem";
        hostPath = cfg.secrets.cachePrivateKey;
        isReadOnly = true;
      };

      config = { ... }: {
        services.nix-serve = mkIf cfg.cache.enable {
          enable = true;
          secretKeyFile = "/var/secrets/runner/cache-private-key.pem";
          package = cfg.cache.package;
          bindAddress = "localhost";
          port = cfg.cache.port;
        };
      };
    };

    # Public binary cache vhost (host side). Requires nginx to be configured
    # on the host; the module only adds the virtual host.
    services.nginx = mkIf cfg.cache.enable {
      virtualHosts.${cfg.cache.domain} = {
        enableACME = true;
        forceSSL = true;
        locations."/".proxyPass = "http://localhost:${toString cfg.cache.port}";
      };
    };
  };
}

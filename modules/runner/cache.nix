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

      nginxCache = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the nginx virtual host caches nix-serve responses.
            NARs are immutable, so the edge cache absorbs backend restarts
            and slow on-the-fly dumps under IO pressure: request coalescing
            reduces duplicate upstream fetches, and content still resident in
            the cache can be served stale when the upstream errors or times
            out. Disable to restore plain proxying. The zone lives at
            `/var/cache/nginx/nixtache-bincache` (fixed by the nixpkgs nginx
            module) on the host root filesystem rather than the cache store's
            disk.
          '';
        };

        maxSize = mkOption {
          type = types.str;
          default = "10g";
          description = ''
            Maximum size of the nginx cache zone (`max_size`). The zone
            holds only hot responses, not the whole store; entries unused for
            30 days are evicted by `inactive`, and capacity pressure can evict
            them earlier.
          '';
        };
      };
    };

    # --- Secrets (path-based, supplied by the consumer) -------------------
    # The registration token is per-instance (`instances.<name>.tokenFile`);
    # SSH creds live in `flakeSshCreds` / `updateSshCreds` (ssh.nix). Secret
    # paths are supplied directly by the consumer's chosen backend.
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

        # Interactive cache fetches must not starve behind batch CI builds
        # when the store disk is saturated: nix-serve gets a mild CPU/IO edge
        # over the (default-scheduled) forgejo-runner units.
        systemd.services.nix-serve = mkIf cfg.cache.enable {
          serviceConfig = {
            Nice = -5;
            IOSchedulingClass = "best-effort";
            IOSchedulingPriority = 0;
          };
        };
      };
    };

    # Public binary cache vhost (host side). Requires nginx to be configured
    # on the host; the module only adds the virtual host.
    services.nginx = mkIf cfg.cache.enable (mkMerge [
      {
        virtualHosts.${cfg.cache.domain} = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://localhost:${toString cfg.cache.port}";
            # narinfo: content is immutable per path hash, but a long TTL
            # would leave narinfos pointing at retain-GC'd NARs; a ~1m 404
            # TTL keeps freshly pushed paths visible to clients promptly.
            extraConfig = mkIf cfg.cache.nginxCache.enable ''
              proxy_cache nixtache-bincache;
              proxy_cache_valid 200 6h;
              proxy_cache_valid 404 1m;
              proxy_cache_lock on;
              proxy_cache_lock_timeout 300s;
              proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
              proxy_read_timeout 300s;
            '';
          };
        };
      }

      (mkIf cfg.cache.nginxCache.enable {
        # NARs are immutable: use a long TTL and coalesce concurrent cache
        # misses to reduce duplicate upstream dump-path requests.
        virtualHosts.${cfg.cache.domain}.locations."/nar/" = {
          proxyPass = "http://localhost:${toString cfg.cache.port}";
          extraConfig = ''
            proxy_cache nixtache-bincache;
            proxy_cache_valid 200 30d;
            proxy_cache_lock on;
            proxy_cache_lock_timeout 300s;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            proxy_read_timeout 300s;
          '';
        };

        proxyCachePath."nixtache-bincache" = {
          enable = true;
          levels = "1:2";
          keysZoneName = "nixtache-bincache";
          keysZoneSize = "10m";
          maxSize = cfg.cache.nginxCache.maxSize;
          inactive = "30d";
          useTempPath = false;
        };
      })
    ]);
  };
}

# A/B image staging for `method = "ab-image"` targets (Batch E).
#
# Owns the central image staging directory on the runner host + its HTTPS
# distribution + the GPG signing key for image manifests + a retain-GC. This is
# the runner-SIDE half of ab-image; the target-SIDE half (gating unit that
# triggers `systemd-sysupdate` when runners are idle) lives in
# `modules/deploy-target/ab.nix`.
#
# Flow (see doc/specs/direct-deploy/06-ab-image.md):
#   CI (container) builds `sysupdate-package` → writes versioned files into the
#   central staging dir (bind-mounted into the container) → signs SHA256SUMS
#   with the GPG key → signals the target. Each target's `systemd-sysupdate`
#   reads the image from this dir (local-self: `file://`; remote: HTTPS via the
#   nginx location on the cache vhost) and writes its inactive A/B slot.
#
# The container NEVER writes a disk slot itself (no block-device access) — it
# only stages; sysupdate on each target does the atomic slot write + reboot.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  runnerCfg = config.services.nixtache.runner;
  cfg = runnerCfg.deploy.ab;

  enabledInstances = filterAttrs (_: i: i.enable) runnerCfg.instances;

  # nginx URI prefix and the on-disk staging subdir MUST share their basename so
  # the vhost `root` maps `<stagingPath>` onto the `/<basename>/` URI. Enforced
  # by an assertion below.
  stagingBasename = baseNameOf cfg.stagingPath;
in
{
  options.services.nixtache.runner.deploy.ab = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the central A/B image staging store on this runner host.
        When set, the runner module:
        - creates `stagingPath` (host StateDirectory) and bind-mounts it
          read/write into the container so CI can write built images;
        - serves it over HTTPS by adding `nginx.location` to the existing
          cache virtual host (`cache.enable` must be true) — remote ab-image
          targets pull from there with `systemd-sysupdate` (`Type = url-file`);
        - exposes the GPG signing key to CI (LoadCredential
          `sysupdate_signing_key`) so it can sign each `SHA256SUMS` manifest;
        - exports `NIXTACHE_RUNNER_HOST` + `NIXTACHE_AB_STAGE` to every job (the
          deploy action uses the former to tell local-self targets from remote
          ones, and the latter as the central stage destination);
        - runs a retain GC (`nixtache-ab-gc.{timer,service}`) that trims each
          per-config subdir to the last `retain` image versions.

        Disable when no target uses `method = "ab-image"`. The target-side
        gating/options live in `services.nixtache.deploy-target.ab.*`.
      '';
    };

    stagingPath = mkOption {
      type = types.str;
      default = "/var/lib/nixtache/ab-stage";
      description = ''
        Host directory holding the central image store. Bind-mounted into the
        container at the same path (CI writes here). Layout:
        `<stagingPath>/<cfg>/<imageId>_<version>.{nix-store.raw,efi}` +
        `SHA256SUMS` (+ `.gpg`). The basename of this path MUST equal the
        basename of `nginx.location` (the vhost `root` maps one onto the other).
      '';
    };

    runnerHost = mkOption {
      type = types.str;
      example = "bincache.zinzaguras.ru";
      description = ''
        Reachable address of THIS runner host (the value the deploy action
        compares each target's `host` against to decide local-self vs remote
        ab-image apply). Use the same host as remote targets would resolve to
        reach the nginx-served staging store — typically the cache domain.
      '';
    };

    nginx.location = mkOption {
      type = types.str;
      default = "/ab-stage/";
      description = ''
        nginx URI prefix under the cache virtual host (`cache.domain`) that
        serves the staging store to remote ab-image targets. `autoindex on` is
        forced so `systemd-sysupdate` can enumerate versions over HTTPS. The
        basename MUST match `baseNameOf stagingPath`.
      '';
    };

    retain = mkOption {
      type = types.ints.positive;
      default = 5;
      description = ''
        How many recent image versions to keep per target-config subdir of the
        staging store. The `nixtache-ab-gc` timer trims older versioned files
        (and rewrites `SHA256SUMS`) so the central store's growth stays bounded.
      '';
    };

    signingKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the OpenPGP PRIVATE key (ASCII-armored) CI uses to sign each
        staging `SHA256SUMS` → `SHA256SUMS.gpg` (verified by targets via
        `Transfer.Verify = yes` against `/etc/systemd/import-pubring.pgp`).
        systemd-sysupdate verifies OpenPGP/GPG only — age/sops cannot produce
        the signature it expects — but this key is supplied as a path-based
        secret, so the consumer typically stores it age-encrypted (sops) like
        the deploy keys. `null` disables signing (`Transfer.Verify = no` on
        targets) — only acceptable behind a trusted transport.
      '';
    };
  };

  config = mkIf (runnerCfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = runnerCfg.cache.enable;
        message = "services.nixtache.runner.deploy.ab.enable = true requires services.nixtache.runner.cache.enable = true (the ab-image staging store is served by reusing the cache nginx virtual host).";
      }
      {
        assertion = baseNameOf cfg.nginx.location == stagingBasename;
        message = "services.nixtache.runner.deploy.ab: the basename of nginx.location (${baseNameOf cfg.nginx.location}) must equal the basename of stagingPath (${stagingBasename}) so the vhost root maps one onto the other.";
      }
      {
        assertion = cfg.runnerHost != "";
        message = "services.nixtache.runner.deploy.ab.runnerHost must be set (the deploy action compares each target's `host` against it to tell local-self from remote ab-image apply).";
      }
    ];

    # --- central staging dir on the host (writable by CI) ---------------------
    # Mode 0777 is intentional: the staging dir holds only build artifacts whose
    # integrity is enforced by the detached GPG signature on SHA256SUMS — a
    # process that can write here cannot forge SHA256SUMS.gpg without the
    # signing key, so it can DoS but not inject a signed bad image. World-write
    # lets the container's CI user (whose name the host doesn't know) write
    # without fragile UID mapping. Sticky bit prevents cross-job file deletion.
    systemd.tmpfiles.rules = [
      "d ${cfg.stagingPath} 1777 root root -"
    ];

    # --- staging store bind-mounted into the container (CI writes images) -----
    containers.${runnerCfg.containerName} = {
      bindMounts."ab-stage" = {
        mountPoint = cfg.stagingPath;
        hostPath = cfg.stagingPath;
        isReadOnly = false;
      };

      config = { ... }: {
        # gpg is needed by the deploy action to sign SHA256SUMS at stage time.
        environment.systemPackages = [ pkgs.gnupg ];

        # Expose the signing key to every gitea-runner-* service (same pattern
        # as the deploy keys in deploy.nix). The action imports it into a
        # throwaway GNUPGHOME, signs, and discards.
        systemd.services = mapAttrs' (iname: _:
          nameValuePair "gitea-runner-${iname}" {
            serviceConfig.LoadCredential = mkIf (cfg.signingKeyFile != null) [
              "sysupdate_signing_key:${toString cfg.signingKeyFile}"
            ];
          }
        ) enabledInstances;
      };
    };

    # --- staging store served over HTTPS (remote ab-image targets) ------------
    # Reuses the cache vhost (domain + TLS). `root` = parent of stagingPath so a
    # request `/ab-stage/<cfg>/<id>_<v>.raw` maps onto `<stagingPath>/<cfg>/...`.
    services.nginx.virtualHosts.${runnerCfg.cache.domain}.locations.${cfg.nginx.location} = {
      root = dirOf cfg.stagingPath;
      extraConfig = ''
        autoindex on;                            # sysupdate enumerates versions over HTTPS dir-listing
        default_type application/octet-stream;   # .raw / .efi
        location ~ /SHA256SUMS$        { default_type text/plain; }
        location ~ /SHA256SUMS\.gpg$   { default_type application/pgp-signature; }
      '';
    };

    # --- envs to every job: runner host identity + staging destination --------
    services.nixtache.runner._extraRunnerEnvs = {
      NIXTACHE_RUNNER_HOST = cfg.runnerHost;
      NIXTACHE_AB_STAGE = cfg.stagingPath;
    };

    # --- retain GC: trim each <cfg>/ subdir to the last `retain` versions ------
    # Runs on the host (sees the real staging dir). For each per-config subdir,
    # keeps the `retain` newest `<id>_<v>.{raw,efi}` tuples (by version) and
    # removes older ones, then regenerates that subdir's SHA256SUMS from the
    # survivors + re-signs SHA256SUMS.gpg with the signing key (if provisioned).
    # Without re-signing, remote targets with Transfer.Verify=yes would reject
    # the stale .gpg (signed over the pre-GC file list).
    systemd.services.nixtache-ab-gc = {
      description = "nixtache ab-image staging retain GC (keep N newest versions per config)";
      path = with pkgs; [ coreutils findutils gawk ]
        ++ optional (cfg.signingKeyFile != null) gnupg;
      serviceConfig = {
        Type = "oneshot";
      };
      script = let
        signingKey = toString cfg.signingKeyFile;
      in ''
        set -uo pipefail
        stage="${cfg.stagingPath}"
        retain=${toString cfg.retain}
        [ -d "$stage" ] || exit 0
        for cfgdir in "$stage"/*/ ; do
          [ -d "$cfgdir" ] || continue
          # Collect distinct versions from the .nix-store.raw filenames
          # (`<id>_<v>.nix-store.raw`); keep the `retain` newest, delete the rest
          # (both the .raw and its matching .efi).
          versions=$(ls -1 "$cfgdir"*.nix-store.raw 2>/dev/null \
            | sed -nE 's/.*_([0-9]+)\.nix-store\.raw$/\1/p' \
            | sort -rn | awk "NR>''${retain}")
          for v in $versions; do
            rm -f "$cfgdir"*_"$v".nix-store.raw "$cfgdir"*_"$v".efi
          done
          # Regenerate SHA256SUMS from the survivors. Empty subdir → no manifest.
          if ls "$cfgdir"*.nix-store.raw >/dev/null 2>&1; then
            ( cd "$cfgdir" && sha256sum *.raw *.efi > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
            # Re-sign so targets with Transfer.Verify=yes don't reject a stale .gpg.
            # The signing key is a host-path (sops secret) — accessible from the host.
            ${optionalString (cfg.signingKeyFile != null) ''
              if [ -f "${signingKey}" ]; then
                GNUPGHOME=$(mktemp -d); export GNUPGHOME
                gpg --batch --import "${signingKey}" 2>/dev/null
                ( cd "$cfgdir" && gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS ) \
                  || echo "WARNING: GC re-sign failed for $cfgdir — .gpg stale"
                rm -rf "$GNUPGHOME"
              else
                rm -f "$cfgdir/SHA256SUMS.gpg"
              fi
            ''}
            ${optionalString (cfg.signingKeyFile == null) ''
              rm -f "$cfgdir/SHA256SUMS.gpg"
            ''}
          else
            rm -f "$cfgdir/SHA256SUMS" "$cfgdir/SHA256SUMS.gpg"
          fi
        done
      '';
    };

    systemd.timers.nixtache-ab-gc = {
      description = "Periodic nixtache ab-image staging retain GC";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}

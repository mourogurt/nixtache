# Unified auto-update channel — the nixtache replacement for `system.autoUpgrade`.
#
# One module, two mechanisms chosen per system type (`method = "auto"` derives):
#
#   - flake (non-OTA): the poll service builds the target toplevel from the
#     configured flake ref and activates it THROUGH the shared
#     `nixtache-apply.service` (pointer write + oneshot start) — never raw
#     `nixos-rebuild` — so the probe/rollback safety net of the deploy
#     pipeline applies to timer-driven updates exactly as to CI deploys.
#   - ab-image (OTA): the poll service triggers `systemd-sysupdate` and owns
#     ONLY the trigger + reboot policy. Transfers/Source/slots stay with
#     ab-provision/ab-image (one owner per concern); idle-gating on the
#     runner host stays with `nixtache-ab-apply` — on a gating
#     host the service is a no-op by design (`ab.poll` derives false there).
#
# Standalone by contract: every access to a sibling module's config goes
# through `builtins.hasAttr`/`or`-guards (pattern from ab-provision.nix), so a
# consumer may import ONLY this module. Missing siblings are reported via
# soft assertions instead of `attribute missing` eval errors.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.nixtache.auto-update;

  nixtache = config.services.nixtache;
  dt = nixtache.deploy-target or { };
  dtAb = dt.ab or { };
  abImage = nixtache.ab-image or { };

  dtEnabled = dt.enable or false;
  dtAbEnabled = dtAb.enable or false;
  abImageEnabled = abImage.enable or false;
  gating = dtAb.gating or false;
  sysupdateEnabled = config.systemd.sysupdate.enable or false;
  dtAbPartitions = dtAb.partitions or { };
  # The ab path needs a resolvable update source: the ab-image module,
  # ab.partitions with a source, or consumer-owned sysupdate transfers that
  # already carry a Source.
  sysupdateTransfers = config.systemd.sysupdate.transfers or { };
  transfersHaveSource = builtins.any (t: t ? Source && t.Source ? Path)
    (builtins.attrValues sysupdateTransfers);
  abSourceResolvable = abImageEnabled
    || ((dtAbPartitions.enable or false) && (dtAbPartitions.source or null) != null)
    || transfersHaveSource;

  abPresent = dtAbEnabled || abImageEnabled;
  effectiveMethod =
    if cfg.method != "auto" then cfg.method
    else if abPresent then "ab-image"
    else "flake";
  isFlake = effectiveMethod == "flake";
  isAb = effectiveMethod == "ab-image";
  sysupdateService =
    if versionAtLeast config.systemd.package.version "262"
    then "systemd-sysupdate-update.service"
    else "systemd-sysupdate.service";

  stateDir = "/var/lib/nixtache";
  pendingFile = "${stateDir}/pending-system";
  rebootPendingFile = "${stateDir}/reboot-pending";

  # git-style URLs take `?ref=<ref>`; shorthand refs (github:org/repo, plain
  # paths) take `/<ref>`. null = the ref is baked into the URL already.
  flakeUrl =
    if cfg.flake.ref == null then cfg.flake.url
    else if hasInfix "://" cfg.flake.url then "${cfg.flake.url}?ref=${cfg.flake.ref}"
    else "${cfg.flake.url}/${cfg.flake.ref}";
  flakeConf =
    if cfg.flake.configuration != null then cfg.flake.configuration
    else config.networking.hostName;
  buildTarget = "${flakeUrl}#nixosConfigurations.${flakeConf}.config.system.build.toplevel";

  markerFn = ''
    marker() { echo "nixtache-auto-update: $1"; }
  '';

  # Reboot policy, flake path. `if-needed`/`window` compare the booted kernel
  # against the freshly activated one; `window` defers the reboot itself to
  # nixtache-auto-update-reboot.timer via the marker file.
  kernelCompare = ''
    booted=$(readlink -f /run/booted-system/kernel 2>/dev/null || true)
    current=$(readlink -f /run/current-system/kernel 2>/dev/null || true)
  '';
  flakeRebootClause =
    if cfg.rebootPolicy == "never" then ""
    else if cfg.rebootPolicy == "if-needed" then ''
      ${kernelCompare}
      if [ -n "$booted" ] && [ "$booted" != "$current" ]; then
        marker "kernel changed — rebooting"
        systemctl reboot
      fi
    ''
    else ''
      ${kernelCompare}
      if [ -n "$booted" ] && [ "$booted" != "$current" ]; then
        touch "${rebootPendingFile}"
        marker "kernel changed — reboot pending (window ${cfg.rebootWindow.start}-${cfg.rebootWindow.end})"
      fi
    '';

  # Activation mechanics: build → no-op check → CI-precedence skip →
  # atomic pointer write (tmp+rename, the pointer is shared with CI deploys)
  # → shared apply oneshot. apply failure means the probe rolled the
  # profile back; propagate it so the run shows red.
  flakeScript = ''
    set -uo pipefail
    ${markerFn}
    ${optionalString (cfg.flake.sshPrivateKeyFile != null) ''
      export GIT_SSH_COMMAND="ssh -i ''${CREDENTIALS_DIRECTORY}/auto_update_ssh_key -o IdentitiesOnly=yes"
    ''}
    new=$(nix build --extra-experimental-features "nix-command flakes" --no-link --print-out-paths \
      ${escapeShellArg buildTarget} ${concatStringsSep " " (map escapeShellArg cfg.flake.flags)})
    marker "built $new"
    cur=$(readlink -f /run/current-system)
    if [ "$new" = "$cur" ]; then
      marker "already at $new"
      exit 0
    fi
    if [ -f "${pendingFile}" ]; then
      marker "CI deploy pending — skipping"
      exit 0
    fi
    echo "$new" > "${stateDir}/pending-system.tmp"
    mv "${stateDir}/pending-system.tmp" "${pendingFile}"
    systemctl start nixtache-apply.service || { marker "nixtache-apply failed (probe rolled back) — giving up"; exit 1; }
    ${flakeRebootClause}
  '';

  # AB mechanics: sysupdate never reboots by itself (a transfer with
  # `Reboot = yes` gets warned about below) — this unit detects "a new version
  # landed" from the sysupdate journal and applies the unified reboot policy.
  abRebootClause =
    if cfg.rebootPolicy == "never" then ""
    else if cfg.rebootPolicy == "if-needed" then ''
      if [ "$installed" = 1 ]; then
        marker "image installed — rebooting"
        systemctl reboot
      fi
    ''
    else ''
      if [ "$installed" = 1 ]; then
        touch "${rebootPendingFile}"
        marker "image installed — reboot pending (window ${cfg.rebootWindow.start}-${cfg.rebootWindow.end})"
      fi
    '';
  abPollScript = ''
    set -uo pipefail
    ${markerFn}
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    marker "triggered sysupdate"
    if ! systemctl start --wait ${sysupdateService}; then
      marker "systemd-sysupdate failed to start"
      exit 1
    fi
    sleep 1  # let journald flush the update run's final messages
    if systemctl is-failed --quiet ${sysupdateService}; then
      marker "systemd-sysupdate run failed"
      exit 1
    fi
    installed=0
    # journalctl -u does not resolve unit aliases: the stock update unit
    # records under its canonical name systemd-sysupdate-update.service, a
    # local override under the alias name — query both.
    if journalctl -u systemd-sysupdate-update.service -u systemd-sysupdate.service --since "$t0" --no-pager | grep -q "Successfully installed"; then
      installed=1
      marker "new image installed"
    else
      marker "no new image installed"
    fi
    ${abRebootClause}
  '';

  # Gating host: activation + reboot are owned by nixtache-ab-apply
  # (idle-gate over the CI signal). The timer channel is a deliberate no-op.
  abGatingScript = ''
    set -u
    echo "nixtache-auto-update: ab.poll=false — ci-driven channel, nothing to do"
  '';

  # Transfers belong to ab-provision/ab-image; this only WARNS when one of
  # them would reboot behind the reboot policy's back.
  transferReboots = any
    (t: (t.Transfer.Reboot or "no") == "yes")
    (attrValues (config.systemd.sysupdate.transfers or { }));
in
{
  options.services.nixtache.auto-update = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the unified auto-update channel on this target (the nixtache
        replacement for `system.autoUpgrade`). Incompatible with
        `system.autoUpgrade.enable = true` (asserted).
      '';
    };

    method = mkOption {
      type = types.enum [ "auto" "flake" "ab-image" ];
      default = "auto";
      description = ''
        Update mechanism. `"auto"` (default) derives from the co-imported
        modules: `ab-image.enable` or `deploy-target` `ab.enable` →
        `"ab-image"`, otherwise `"flake"`. An explicit value disables the
        derivation (the escape hatch, e.g. an A/B transition period where the
        image is already being built but updates still flow through the flake
        path) — the same assertions validate it either way.
      '';
    };

    dates = mkOption {
      type = types.str;
      default = "daily";
      example = "Mon 03:30";
      description = ''
        systemd OnCalendar expression for the `nixtache-auto-update.timer`
        poll schedule. Shared by both paths. Recommended role: auto-update is
        the fallback channel behind CI deploys, so a sparse schedule (daily/
        weekly) with a large `randomizedDelaySec` is typical.
      '';
    };

    randomizedDelaySec = mkOption {
      type = types.str;
      default = "1h";
      example = "30min";
      description = ''
        systemd RandomizedDelaySec for the poll timer — spreads pulls across a
        fleet so targets don't hit the deployer/git host simultaneously.
      '';
    };

    persistent = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Persistent= on the poll timer: a run missed while the machine was off
        is caught up at the next boot. Important for laptop/desktop-style
        targets that are not always on.
      '';
    };

    flake = {
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "git+ssh://forgejo@git.example.com/org/config.git";
        description = ''
          Flake reference to build the system from (`"git+ssh://host/org/repo.git"`,
          `"github:org/repo"`, a local path like `"/etc/nixos"`). Required when
          the effective method is `"flake"` (asserted).
        '';
      };

      ref = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "release";
        description = ''
          Branch/ref to append to `flake.url`: `?ref=<ref>` for git URLs,
          `/<ref>` for shorthand refs (`github:`/paths). `null` (default) =
          the ref is already baked into the URL (or the default branch is
          wanted).
        '';
      };

      configuration = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Attribute name inside `nixosConfigurations` to build: the build
          target is `<url>#nixosConfigurations.<configuration>.config.system.build.toplevel`.
          `null` (default) uses `config.networking.hostName` — the same
          convention as the runner-side deploy map.
        '';
      };

      flags = mkOption {
        type = types.listOf types.str;
        default = [ "--refresh" "-L" ];
        description = ''
          Extra flags passed to `nix build` (the equivalent of
          `system.autoUpgrade.flags`).
        '';
      };

      sshPrivateKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path-based secret (sops/agenix/systemd credential) holding the SSH
          private key used to fetch a PRIVATE flake or private inputs.
          Mounted into the service via LoadCredential and exported as
          GIT_SSH_COMMAND. `null` (default) = fetch without a key (public
          flake, or ssh already configured system-wide).
        '';
      };
    };

    rebootPolicy = mkOption {
      type = types.enum [ "never" "if-needed" "window" ];
      default = "never";
      description = ''
        Unified reboot policy for both paths.
        - `"never"` (default): switch / write the slot only; rebooting is the
          operator's business. Mandatory on a gating host (asserted) — the
          idle-gated `nixtache-ab-apply` owns the reboot there.
        - `"if-needed"`: flake path reboots when the booted kernel differs
          from the newly activated one; ab-image path reboots right after a
          new image was installed (an image update always needs a reboot).
        - `"window"`: like `"if-needed"`, but the reboot is deferred — a
          marker file is dropped and `nixtache-auto-update-reboot.timer`
          (OnCalendar = `rebootWindow.start`) consumes it once the current
          time is inside `rebootWindow`.
      '';
    };

    rebootWindow = {
      start = mkOption {
        type = types.str;
        default = "02:00";
        example = "23:30";
        description = ''
          Window start (`HH:MM`) for `rebootPolicy = "window"`. Also the
          OnCalendar of `nixtache-auto-update-reboot.timer`. Must differ from
          `rebootWindow.end` (asserted — an empty window would never fire).
          A window may cross midnight.
        '';
      };

      end = mkOption {
        type = types.str;
        default = "05:00";
        example = "04:30";
        description = ''
          Window end (`HH:MM`) for `rebootPolicy = "window"`. Outside the
          window the reboot timer leaves the marker pending and waits for the
          next run.
        '';
      };
    };

    ab = {
      poll = mkOption {
        type = types.bool;
        # Runner-host (gating) targets are CI-driven by design: CI stages the
        # image and signals ab-pending, nixtache-ab-apply idle-gates the
        # apply+reboot. A second pull trigger would add no information.
        default = !gating;
        defaultText = literalExpression
          "!config.services.nixtache.deploy-target.ab.gating or false";
        description = ''
          Whether the poll timer triggers `systemd-sysupdate` on the ab-image
          path. `true` (remote targets): the timer pulls the staged image
          into the inactive slot. `false` (derived on gating/runner hosts):
          the service is provisioned but exits with a `ci-driven` journal
          marker — activation and reboot stay with the idle-gated
          `nixtache-ab-apply`. Only meaningful on the ab-image path.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !config.system.autoUpgrade.enable;
          message = ''
            services.nixtache.auto-update replaces system.autoUpgrade — set
            system.autoUpgrade.enable = false (the drop-in equivalent is in
            doc/user_guide/auto-update.md).
          '';
        }
        {
          assertion = !isFlake || dtEnabled;
          message = ''
            services.nixtache.auto-update: the flake path activates through
            nixtache-apply.service, which is provided by the deploy-target
            module. Import inputs.nixtache.nixosModules.deploy-target
            (deployUser may stay null — the timer runs as root and needs no
            SSH facade).
          '';
        }
        {
          assertion = !isFlake || cfg.flake.url != null;
          message = ''
            services.nixtache.auto-update.flake.url is required when
            method = "flake" (including method = "auto" deriving to flake).
          '';
        }
        # The ab path needs BOTH a running sysupdate AND a resolvable
        # image source (ab-image module, or ab.partitions with a source).
        {
          assertion = !isAb || (sysupdateEnabled && abSourceResolvable);
          message = ''
            services.nixtache.auto-update: the ab-image path requires
            systemd.sysupdate.enable = true AND a resolvable update source —
            enable nixosModules.ab-image, or set deploy-target
            ab.partitions.{enable,source}. auto-update only triggers the pull;
            the transfers/source stay with those modules.
          '';
        }
        {
          assertion =
            cfg.rebootPolicy != "window"
            || cfg.rebootWindow.start != cfg.rebootWindow.end;
          message = ''
            services.nixtache.auto-update: rebootPolicy = "window" with
            rebootWindow.start == rebootWindow.end (${cfg.rebootWindow.start})
            is an empty reboot window — the deferred reboot would never fire.
          '';
        }
        {
          assertion = !(isAb && gating && cfg.rebootPolicy != "never");
          message = ''
            services.nixtache.auto-update: on a gating host (deploy-target
            ab.gating = true) the reboot is owned by nixtache-ab-apply
            (idle-gate) — rebootPolicy must be "never".
          '';
        }
        {
          assertion = !(cfg.method == "ab-image" && !abPresent && !sysupdateEnabled);
          message = ''
            services.nixtache.auto-update.method = "ab-image" is set
            explicitly, but no A/B machinery is enabled: neither
            services.nixtache.ab-image.enable nor deploy-target ab.enable is
            on, and systemd.sysupdate is disabled — typo? (During an A/B
            transition you can enable systemd.sysupdate manually; otherwise
            import the ab-image/deploy-target modules.)
          '';
        }
      ];

      # A transfer that reboots itself bypasses the unified rebootPolicy.
      warnings = optional (isAb && transferReboots) ''
        services.nixtache.auto-update owns the reboot policy (rebootPolicy);
        remove Reboot=yes from the systemd.sysupdate transfers.
      '';

      systemd.timers.nixtache-auto-update = {
        description = "Poll timer for the nixtache auto-update channel";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.dates;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = cfg.persistent;
        };
      };

      systemd.services.nixtache-auto-update = {
        description = "nixtache auto-update: pull and stage a system update (${effectiveMethod} path)";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        path = with pkgs; [ systemd coreutils gnugrep ]
          ++ optional isFlake config.nix.package
          ++ optional (isFlake && cfg.flake.sshPrivateKeyFile != null) openssh;
        serviceConfig = {
          Type = "oneshot";
        } // optionalAttrs (isFlake && cfg.flake.sshPrivateKeyFile != null) {
          LoadCredential = [ "auto_update_ssh_key:${toString cfg.flake.sshPrivateKeyFile}" ];
        };
        script =
          if isFlake then flakeScript
          else if cfg.ab.poll then abPollScript
          else abGatingScript;
      };
    }

    (mkIf (cfg.rebootPolicy == "window") {
      # Deferred reboot: fires at rebootWindow.start, consumes the marker only
      # while inside the window; a missed window waits for the next run.
      systemd.timers.nixtache-auto-update-reboot = {
        description = "Deferred reboot timer for the nixtache auto-update channel";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.rebootWindow.start;
          Persistent = true;
        };
      };

      systemd.services.nixtache-auto-update-reboot = {
        description = "nixtache auto-update: reboot inside the configured window when a reboot is pending";
        path = with pkgs; [ systemd coreutils ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -u
          [ -f "${rebootPendingFile}" ] || { echo "nixtache-auto-update-reboot: no pending reboot — nothing to do"; exit 0; }
          now=$(date +%H:%M)
          start="${cfg.rebootWindow.start}"
          end="${cfg.rebootWindow.end}"
          if [ "$start" \< "$end" ]; then
            inside=0
            { [ "$now" \> "$start" ] || [ "$now" = "$start" ]; } && { [ "$now" \< "$end" ]; } && inside=1
          else
            inside=0
            { [ "$now" \> "$start" ] || [ "$now" = "$start" ] || [ "$now" \< "$end" ]; } && inside=1
          fi
          if [ "$inside" = 1 ]; then
            echo "nixtache-auto-update-reboot: inside reboot window ($start-$end) — rebooting"
            rm -f "${rebootPendingFile}"
            systemctl reboot
          else
            echo "nixtache-auto-update-reboot: outside reboot window ($start-$end) — waiting for the next window"
          fi
        '';
      };
    })
  ]);
}

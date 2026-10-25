# Shared option types for the runner module.
#
# Not a NixOS module — a plain function `{ lib }: { ... }` imported by the
# sub-modules that need these types (default.nix, ssh.nix, known-hosts.nix,
# instances.nix). Keeping them here avoids re-declaring the same submodules in
# every file and gives one place to edit when the shape of an instance / SSH
# credential / known-host entry changes.
{ lib }:

let
  inherit (lib) types mkOption;
in
{
  # Known-host entry: a named SSH host key trusted inside the container.
  knownHostEntry = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Arbitrary key under services.openssh.knownHosts.";
      };
      hostNames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Host names / IPs / aliases this key is valid for.";
      };
      publicKey = mkOption {
        type = types.str;
        description = "The SSH public key line.";
      };
    };
  };

  # A single runner instance. All instances share the container's relocated
  # nix store, SSH/bot keys, cache and Forgejo URL; they differ by `uuid`,
  # `labels` and `tokenFile` — each instance is its own Forgejo registration
  # (its own uuid + token pair), so Forgejo can route jobs to a specific
  # runner (e.g. a "test" runner on a distinct label with its own pair).
  # The runner NAME is fixed when the registration is created in Forgejo and
  # is not configured here: runners no longer self-report their name.
  instanceType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this runner instance.";
      };
      uuid = mkOption {
        type = types.str;
        example = "c9e50be9-a7c3-4aee-ba35-624c4ff8c519";
        description = ''
          UUID of THIS instance's Forgejo runner registration. Runners no
          longer self-register: the uuid + token pair is obtained from Forgejo
          when the registration is created (one pair per instance). Not a
          secret — the generated runner config carries it verbatim.
        '';
      };
      labels = mkOption {
        type = types.listOf types.str;
        default = [ "nixos:host" ];
        description = "Runner labels (Forgejo routes jobs to instances by label).";
      };
      tokenFile = mkOption {
        type = types.path;
        description = ''
          File containing the bare runner token of THIS instance's Forgejo
          registration — just the token, no `TOKEN=` prefix, no
          environment-file syntax (the pair to `uuid`, obtained from Forgejo
          when the registration is created). One token per instance.
          Supplied by the consumer (sops / vault / systemd / ...).
        '';
      };
    };
  };

  # SSH credentials for a single purpose: a user (server RUN_USER) + key pair.
  # Two independent bundles exist — one for fetching private flake inputs
  # (`flakeSshCreds`, used by nix-check's `nix flake check`), one for the
  # update-flake workflow (`updateSshCreds`, push + commit signing). They mount
  # as separate LoadCredentials (flake_ssh_* / update_ssh_*); typically the
  # consumer points both at the same key files.
  sshCredsType = types.submodule {
    options = {
      user = mkOption {
        type = types.str;
        description = "SSH user (server `RUN_USER`, e.g. `forgejo`/`git`) for this credential.";
      };
      sshPrivateKey = mkOption {
        type = types.path;
        description = "Bot SSH private key file path.";
      };
      sshPublicKey = mkOption {
        type = types.path;
        description = "Bot SSH public key file path matching `sshPrivateKey`.";
      };
    };
  };

  # A single direct-deploy target. The attribute name MUST match the consumer's
  # `nixosConfigurations.<name>` — the discovery step of the `deploy-target`
  # action matches configs to targets by that name. Only the non-secret subset
  # of each target is serialized into the job env (`NIXTACHE_DEPLOY_TARGETS`);
  # the private key is bind-mounted via LoadCredential (`deploy_ssh_<name>`),
  # mirroring the `flake_ssh_*` / `update_ssh_*` pattern.
  deployTargetType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this target is eligible for direct deploy. `false` = the
          target is declared in the map but temporarily excluded (the action
          skips it with a warning). Absence from the map entirely means "not a
          deploy target at all".
        '';
      };

      host = mkOption {
        type = types.str;
        example = "10.13.37.3";
        description = ''
          Address of the target machine: LAN/VPN/public IP or DNS name. This is
          the `config → host` leg of the map; the action SSHes here as
          `sshUser@host` on `sshPort`.
        '';
      };

      sshUser = mkOption {
        type = types.str;
        default = "nixos-deploy";
        description = ''
          SSH transport user for deploy. MUST match `deployUser.name` of the
          receiving module (`nixosModules.deploy-target`) on that target: the
          action SSHes in as this user to push the closure (`nix copy --to`),
          write the apply pointer, and trigger `nixtache-apply.service` via
          polkit (no sudo/doas/run0 — V2). Use `root` only if the target is
          deployed via root SSH without the receiving module.
        '';
      };

      sshPort = mkOption {
        type = types.port;
        default = 22;
        description = "Non-standard SSH port for the target.";
      };

      method = mkOption {
        type = types.enum [ "live" "ab-image" ];
        default = "live";
        description = ''
          How the target is updated.

          - `live` (default): push the built closure over SSH (`nix copy`) and
            activate it in place via the root-owned `nixtache-apply.service`
            (polkit-triggered by the deploy user, probe+rollback inside — see
            the receiving module `nixtache.nixosModules.deploy-target`). Use for
            targets whose activation does not kill the deployer (desktop/laptop).
          - `ab-image`: write a new image into the inactive A/B slot via
            `systemd-sysupdate` and reboot. Required for the chicken-and-egg
            runner host (its live-switch would restart the container the job
            runs in) and needs consumer prep (repart/UKI/sysupdate/boot-counting)
            — see `doc/user_guide/ota.md`.
        '';
      };

      sshPrivateKey = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to the deploy private key for this target (the `host → creds` leg
          of the map). Required for BOTH methods — `live` SSH-authenticates the
          `nix copy` + apply-unit trigger, `ab-image` SSH-triggers sysupdate.
          `null` = no credential, the action skips this target (optionality by
          construction). Supplied by the consumer (sops/agenix/vault/systemd —
          any backend yielding a path).
        '';
      };

      sshPublicKey = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Optional path to the deploy public key matching `sshPrivateKey`.
          When set it is bind-mounted into the container and exposed to jobs as
          the `deploy_ssh_<name>.pub` credential (verification / known_hosts
          bookkeeping). `null` = not provided.
        '';
      };

      system = mkOption {
        type = types.nullOr (types.enum [
          "x86_64-linux"
          "aarch64-linux"
          "i686-linux"
          "aarch64-darwin"
          "x86_64-darwin"
        ]);
        default = null;
        description = ''
          Target architecture. `null` (default) = derive from
          `nixosConfigurations.<name>.config.nixpkgs.hostPlatform` at deploy
          time. Cross-arch builds rely on `boot.binfmt.emulatedSystems` on the
          runner host.
        '';
      };

      extraOptions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra flags appended to the deploy invocation for this target
          (e.g. `[ "--no-substitute-on-target" ]` for `nix copy`).
        '';
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Free-form labels for grouping/filtering targets (documentation,
          selective deploy via `workflow_dispatch`). Not interpreted by the
          action.
        '';
      };

      timeout = mkOption {
        type = types.ints.positive;
        default = 240;
        description = ''
          Per-target timeout (minutes) for build + activation. The deploy-target
          action wraps each target's whole deploy (build, copy, activate) in
          `timeout(1)`; exceeding it fails that target's job.
        '';
      };

      minFreeBytes = mkOption {
        type = types.ints.unsigned;
        default = 5 * 1024 * 1024 * 1024;
        defaultText = lib.literalExpression "5 * 1024 * 1024 * 1024";
        description = ''
          Free-space preset (bytes) for this target's runner-side pre-copy
          disk check. The action refuses the deploy pre-build when the
          target's store filesystem has less free space than this preset, and
          post-build when it has less than (missing-closure-paths estimate x
          1.1 + preset). `0` disables the pre-copy check entirely (no
          free-space query is issued — also useful while a target's SSH gate
          predates the query command). Keep this >= the target-side
          `services.nixtache.deploy-target.minFreeBytes` (the apply-unit
          guard), which it does not read.
        '';
      };
    };
  };

  # Default GitHub known hosts (generic, reusable).
  defaultExtraKnownHosts = [
    {
      name = "github_rsa";
      hostNames = [ "github.com" ];
      publicKey =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q>";
    }
    {
      name = "github_ecdsa";
      hostNames = [ "github.com" ];
      publicKey =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    }
    {
      name = "github_ed25519";
      hostNames = [ "github.com" ];
      publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    }
  ];
}

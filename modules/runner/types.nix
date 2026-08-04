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
  # nix store, SSH/bot keys, cache and Forgejo URL; they differ by `name`,
  # `labels` and `tokenFile` (one registration token per instance) so Forgejo
  # can route jobs to a specific runner (e.g. a "test" runner on a distinct
  # label with its own token).
  instanceType = types.submodule ({ name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this runner instance.";
      };
      name = mkOption {
        type = types.str;
        default = name;
        description = "Runner name as registered in Forgejo (defaults to the instance attribute name).";
      };
      labels = mkOption {
        type = types.listOf types.str;
        default = [ "nixos:host" ];
        description = "Runner labels (Forgejo routes jobs to instances by label).";
      };
      tokenFile = mkOption {
        type = types.path;
        description = ''
          Environment file (a systemd `EnvironmentFile`) containing the
          `TOKEN` variable used to register THIS instance. One token per
          instance — Forgejo issues a registration token per runner.
          Supplied by the consumer (sops / vault / systemd / ...).
        '';
      };
    };
  });

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

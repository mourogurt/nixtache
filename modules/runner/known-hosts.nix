# SSH known hosts trusted inside the container.
#
# Owns `gitHost` (primary Forgejo/git host) and `extraKnownHosts` (defaults to
# GitHub's keys), and wires them into the container's
# `services.openssh.knownHosts`. `openssh.enable` is forced off — the keys are
# only consumed by git/ssh clients, no sshd runs in the container.
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

  # Effective known-hosts list = primary git host (if set) + extras.
  knownHostEntries =
    (optional (cfg.gitHost != null) cfg.gitHost)
    ++ cfg.extraKnownHosts;

  knownHostsAttrset = listToAttrs (
    map (e: nameValuePair e.name { inherit (e) hostNames publicKey; }) knownHostEntries
  );
in
{
  options.services.nixtache.runner = {
    # --- SSH known hosts inside the container ------------------------------
    gitHost = mkOption {
      type = types.nullOr typesT.knownHostEntry;
      default = null;
      description = ''
        Primary Forgejo/git host the runner pushes back to. Provide all
        resolvable names (domain, apex, server IP, localhost) in `hostNames`
        so git operations succeed regardless of the URL form used.
      '';
    };

    extraKnownHosts = mkOption {
      type = types.listOf typesT.knownHostEntry;
      default = typesT.defaultExtraKnownHosts;
      defaultText = lib.literalMD "GitHub host keys";
      description = "Additional SSH known hosts (defaults to github.com keys).";
    };
  };

  config = mkIf cfg.enable {
    containers.${cfg.containerName}.config = { ... }: {
      services.openssh = {
        enable = false;
        knownHosts = knownHostsAttrset;
      };
    };
  };
}

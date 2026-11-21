# The nix feature set nixtache forces on every nix environment it
# assembles. Primary consumer: the runner container (modules/runner/
# default.nix imports this file). Also exported as
# `nixosModules.nix-features` so environments that stand in for runner
# hosts consume the same definition instead of hand-copied lists.
{ ... }:
{
  config.nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}

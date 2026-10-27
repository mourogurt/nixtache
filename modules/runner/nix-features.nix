# The nix feature set nixtache forces on every nix environment it
# assembles. Primary consumer: the runner container (modules/runner/
# default.nix imports this file). Also exported as
# `nixosModules.nix-features` so environments that stand in for runner
# hosts — or otherwise handle nixtache closures without importing the
# whole runner module — consume the SAME definition instead of
# hand-copied lists that drift when this one changes.
#
# `ca-derivations` is load-bearing for AB deployments: the appliance
# closure is content-addressed, and every nix that builds, substitutes,
# copies or serves it — client-side `nix copy --to ssh://…`, server-side
# `nix-store --serve` — rejects CA paths unless the feature is enabled.
{ ... }:
{
  config.nix.settings.experimental-features = [
    "nix-command"
    "flakes"
    "ca-derivations"
  ];
}

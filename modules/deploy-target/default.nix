# Orchestrator for the direct-deploy TARGET module (`nixosModules.deploy-target`).
#
# Imported by EVERY target machine (including, eventually, the nixtache runner
# host itself when switched to `method = "ab-image"`). Composes the
# per-responsibility sub-modules: options, deploy-user provisioning, the live
# `nixtache-apply.service` (V2: activation via root systemd unit + polkit, no
# sudo/doas/run0 — see apply.nix), and the Tier-0 boot-time health-check.
#
# Independent of the runner-side `services.nixtache.runner.deploy.targets` map
# (that's the runner host's concern); this module owns what each TARGET needs
# to receive a deploy safely.
#
# Public surface:
#   nixosModules.deploy-target  →  this module
#   options: services.nixtache.deploy-target.{enable, criticalUnits,
#             healthCheckTimeout, deployUser}
#             services.nixtache.deploy-target.ab.*   (ab-image targets)
{
  ...
}:

{
  imports = [
    ./options.nix
    ./user.nix
    ./apply.nix
    ./health-check.nix
    ./ab.nix
    ./ab-provision.nix
  ];
}

{
  description = "Reusable NixOS CI/CD modules: Forgejo Actions runner, binary cache, deploy contract.";

  # Only used to build `checks.*` (module tests). Module consumers bring their
  # own nixpkgs; this input does not leak into the module contract.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/master";

  outputs = { self, nixpkgs, ... }:
    {
      # NixOS modules. Consumers import via:
      #   inputs.nixtache.nixosModules.runner
      # or the convenience alias:
      #   inputs.nixtache.nixosModules.default
      nixosModules = {
        runner = import ./modules/runner.nix;
        default = self.nixosModules.runner;
      };

      # Pure-evaluation tests for the runner module (see tests/runner.nix).
      # Build with:
      #   nix build .#checks.x86_64-linux.runner
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: rec {
        runner = import ./tests/runner.nix { inherit nixpkgs self system; };
        default = runner;
      });
    };
}

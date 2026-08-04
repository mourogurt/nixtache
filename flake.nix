{
  description = "Reusable NixOS CI/CD modules: Forgejo Actions runner, binary cache, deploy contract.";

  # Only used to build `checks.*` (module tests). Module consumers bring their
  # own nixpkgs; this input does not leak into the module contract.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/master";

  outputs = { self, nixpkgs, ... }:
    {
      # NixOS modules. Consumers import via:
      #   inputs.nixtache.nixosModules.forgejo-runner
      # or the convenience alias:
      #   inputs.nixtache.nixosModules.default
      nixosModules = {
        forgejo-runner = import ./modules/forgejo-runner.nix;
        default = self.nixosModules.forgejo-runner;
      };

      # Pure-evaluation tests for the forgejo-runner module (see
      # tests/forgejo-runner.nix). Build with:
      #   nix build .#checks.x86_64-linux.forgejo-runner
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: rec {
        forgejo-runner = import ./tests/forgejo-runner.nix { inherit nixpkgs self system; };
        default = forgejo-runner;
      });
    };
}

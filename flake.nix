{
  description = "Reusable NixOS CI/CD modules: Forgejo Actions runner, binary cache, deploy contract.";

  outputs = { self, ... }@inputs: {
    # NixOS modules. Consumers import via:
    #   inputs.nixtache.nixosModules.forgejo-runner
    # or the convenience alias:
    #   inputs.nixtache.nixosModules.default
    nixosModules = {
      forgejo-runner = import ./modules/forgejo-runner.nix;
      default = self.nixosModules.forgejo-runner;
    };
  };
}

{
  description = "Reusable NixOS CI/CD modules: Forgejo Actions runner, binary cache, secrets providers, docs helpers.";

  # Only used to build `checks.*` (module tests), `packages.*optionsMarkdown`
  # (this flake's own option docs) and `lib.mkDocs`. Module consumers bring
  # their own nixpkgs; this input does not leak into the module contract.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/master";

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      # --- NixOS modules ---------------------------------------------------
      # Consumers import via:
      #   inputs.nixtache.nixosModules.runner     # the Forgejo Actions runner
      #   inputs.nixtache.nixosModules.secrets    # the secrets provider abstraction
      # or the convenience alias:
      #   inputs.nixtache.nixosModules.default     # = .runner
      nixosModules = {
        runner = import ./modules/runner;
        secrets = import ./modules/secrets.nix;
        default = self.nixosModules.runner;
      };

      # --- Consumer-side helpers ------------------------------------------
      # `nixtache.lib.mkDocs` generates documentation for a consumer's own
      # `nixosConfigurations` + `devShells`. See lib/mkDocs.nix and the
      # README "Documenting your flake" section.
      lib.mkDocs = import ./lib/mkDocs.nix;

      # --- Tests -----------------------------------------------------------
      # Pure-evaluation tests for the runner module (see tests/runner.nix).
      # Build with:
      #   nix build .#checks.x86_64-linux.runner
      checks = forAllSystems (system: rec {
        runner = import ./tests/runner.nix { inherit nixpkgs self system; };
        default = runner;
      });

      # --- This flake's own option docs -----------------------------------
      # Generated from the runner module via `pkgs.nixosOptionsDoc` so the
      # option reference never drifts from the source. CI builds these and
      # uploads them as artifacts (see .forgejo/workflows/docs.yml).
      #
      #   nix build .#optionsMarkdown   # CommonMark reference
      #   nix build .#optionsJSON       # machine-readable
      #
      # We evaluate via the full `nixosSystem` (so every base option the
      # module touches — `assertions`, `containers`, `systemd`, `services.*`,
      # `nix.settings.*` — exists), then pass ONLY the `services.nixtache`
      # subtree to `nixosOptionsDoc`. `optionAttrSetToDocList` walks that
      # subtree, so the reference lists just our options, not the ~6000 base
      # NixOS ones.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          fullEval = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.runner
              { system.stateVersion = lib.trivial.release; }
            ];
          };
          ownDocs = pkgs.nixosOptionsDoc {
            options = fullEval.options.services.nixtache;
          };
        in
        {
          optionsMarkdown = ownDocs.optionsCommonMark;
          optionsJSON = ownDocs.optionsJSON;
          default = self.packages.${system}.optionsMarkdown;
        });
    };
}

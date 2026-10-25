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
      # Shared content-addressed import for the A/B (appliance-image) tests:
      # ab-image asserts a CA evaluation, so every appliance test system
      # evaluates with `nixpkgs.pkgs = <CA import>`. One import per system
      # keeps the eval cache shared across all suites/checks.
      caPkgsFor = system: import nixpkgs { inherit system; config.contentAddressedByDefault = true; };
      caPkgs = caPkgsFor "x86_64-linux"; # the VM suites are x86_64-only
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
        deploy-target = import ./modules/deploy-target;
        ab-image = import ./modules/ab-image;
        overlay-nix = import ./modules/overlay-nix;
        auto-update = import ./modules/auto-update;
        secrets = import ./modules/secrets.nix;
        default = self.nixosModules.runner;
      };

      # --- Consumer-side helpers ------------------------------------------
      # `nixtache.lib.mkDocs` generates documentation for a consumer's own
      # `nixosConfigurations` + `devShells`. See lib/mkDocs.nix and the
      # README "Documenting your flake" section.
      lib.mkDocs = import ./lib/mkDocs.nix;

      # --- Dogfood A/B test configs (used by tests/ab-deploy.nix so the action's
      # `nix build .#nixosConfigurations.abtest-remote…` resolves inside nixtache
      # itself — no separate consumer flake). NOT for real deployment.
      nixosConfigurations.abtest-remote =
        (import ./tests/ab-fixture.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; }).mkAppliance {
          version = "2";          # the version the action deploys (the update)
          signVerify = true;      # target verifies with the test pubring
          dataPartition = true;   # T6: data mount must survive the slot swap
          stagingPath = "http://deployer/ab-stage/abtest-remote"; # deployer's nginx
          deployKeyPub = (import ./tests/ab-fixture.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; }).deployKeyPub;
        };

      # --- Tests -----------------------------------------------------------
      # Pure-evaluation tests only — `nix flake check` BUILDS checks.* of the
      # current system on every CI run, so anything heavier than eval must not
      # live here (see `vmTests` below). Build one with:
      #   nix build .#checks.x86_64-linux.<suite>
      # See doc/technical_details/testing.md for the strategy + the docStrictMode matrix.
      checks = forAllSystems (system: {
        runner = import ./tests/runner.nix { inherit nixpkgs self system; };
        deploy-target = import ./tests/deploy-target.nix { inherit nixpkgs self system; };
        # ab-image module pure-eval: fixed vs max-disk sizing + Verify (fast, no KVM).
        ab-image = import ./tests/ab-image.nix { inherit nixpkgs self system; appliancePkgs = caPkgsFor system; };
        # overlay-nix module pure-eval: upperOnUpdate enum (wipe/reconcile),
        # default, hook wiring. Runtime swap behaviour lives in vmTests.
        overlay-nix = import ./tests/overlay-nix.nix { inherit nixpkgs self system; };
        mkDocs = import ./tests/mkDocs.nix { inherit nixpkgs self system; };
        # ── Conformance / contract tests for the landed A/B modules.
        # Pure-eval suites are fast (no KVM); the `*-vm` suites live in
        # `vmTests` below.
        #   ab-existing  : conformance of the implemented ab-image /
        #                  deploy-target wiring (image layout, transfers, verify).
        ab-existing = import ./tests/ab-existing.nix { inherit nixpkgs self system; appliancePkgs = caPkgsFor system; };
        # Auto-update module pure-eval; its end-to-end VM suite
        # (flake path + ab path) is in `vmTests`.
        auto-update = import ./tests/auto-update.nix { inherit nixpkgs self system; appliancePkgs = caPkgsFor system; };
        # ab-deploy-drift: protocol-drift skip contract of the deploy action
        # (extracted action.yml run text vs a fake pre-change SSH gate) —
        # fast, no KVM.
        ab-deploy-drift = import ./tests/ab-deploy-drift.nix { inherit nixpkgs self system; };
        # ci-workflow-drift: sandbox-probe ordering contract over the real
        # workflow YAMLs (every building job probes the sandbox before its
        # first build step; vmtests.yml applies the SANDBOX_OK flag) — fast,
        # no KVM.
        ci-workflow-drift = import ./tests/ci-workflow-drift.nix { inherit nixpkgs system; };
      });

      # ── KVM-only VM suites (runNixOSTest / QEMU). NOT part of `checks`:
      # `nix flake check` would build them on every CI run — the nspawn CI
      # runner cannot chew through 15 QEMU suites (kvm sits in its inherited
      # system-features, so nix would dispatch them locally and drown/timeout).
      # `vmTests` is not a checked output: flake check skips it entirely.
      # Run explicitly on a KVM host (e.g. a dev box):
      #   nix build .#vmTests.x86_64-linux.<suite>
      # All suites carry their KVM requirement (requiredSystemFeatures in the
      # runCommand wrappers, requiredFeatures.kvm in the raw runNixOSTest
      # ones) → non-KVM hosts get an immediate "required system feature"
      # error instead of a TCG crawl.
      vmTests.x86_64-linux = {
        # ab-deploy server-side (runNixOSTest: real runner module nginx + staging
        # + signing) + action.yml parser.
        ab-deploy = import ./tests/ab-deploy.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-e2e: full combat OTA scenario via runNixOSTest (deployer+target VMs,
        # action.yml parsed → sysupdate writes slot B). Base variant = squashfs +
        # zstd; the erofs / tool-default / percent-slotSize variants below cover
        # the remaining matrix through the same OTA path (the build-side
        # compression matrix lives in ab-compression-vm).
        ab-ota-e2e = import ./tests/ab-ota-e2e.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # A3: erofs store images.
        ab-ota-e2e-erofs = import ./tests/ab-ota-e2e.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; variant = { storeFs = "erofs"; storeCompression = "zstd"; }; };
        # A4: no explicit compression (mkfs tool defaults).
        ab-ota-e2e-none = import ./tests/ab-ota-e2e.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; variant = { storeCompression = null; }; };
        # A5: percent slotSize resolved against the target disk (25% of 2 GiB).
        ab-ota-e2e-percent = import ./tests/ab-ota-e2e.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; variant = { slotSize = "25%"; }; };
        # ab-ota-anywhere-vm: full OTA lifecycle in one test — nixos-anywhere
        # install (kexec → disko A/B → UKI boot from the installed disk) then
        # a signed v2 sysupdate onto slot B. Heaviest suite.
        ab-ota-anywhere-vm = import ./tests/ab-ota-anywhere-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # A/B image VM integration tests (Batch E): builds real A/B disk
        # images + runs QEMU.
        ab-vm = import ./tests/ab-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # QEMU (KVM) behavioral contracts for the new modules:
        ab-provision-vm = import ./tests/ab-provision-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; };
        overlay-nix-vm = import ./tests/overlay-nix-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # overlay-nix-install-vm: O2/O3 contract — fetch hello from a binary cache
        # (deployer node running nix-serve-ng) through the local-overlay store →
        # runs + lands in the upper layer. Hermetic (no internet).
        overlay-nix-install-vm = import ./tests/overlay-nix-install-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; };
        # overlay-nix-ab-swap-vm: O9 — overlay upper survives an A/B slot swap:
        # boot v1 appliance → install vim into upper → sysupdate to v2 → reboot
        # into v2 → vim still works + v2 lower visible. 2-boot, heavy.
        overlay-nix-ab-swap-vm = import ./tests/overlay-nix-ab-swap-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # overlay-nix-ota-invalid-vm: overlay-nix across a real OTA swap on the
        # shipped world A (the image carries the lower store DB — loaded at
        # boot, no manual seed): shipped validity out of the box, a delta-only
        # install, then the swap pins the lifecycle matrix. Baseline = the
        # module default ("wipe"); the explicit-wipe variant pins the value;
        # reconcile / degraded-reconcile cover the substituter repair
        # (degraded cuts the cache before the swap: red unit, intact boot,
        # marker retry heals). tmpfs upper: nothing persists — overlay health
        # across the swap only.
        overlay-nix-ota-invalid-vm = import ./tests/overlay-nix-ota-invalid-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        overlay-nix-ota-invalid-wipe-vm = import ./tests/overlay-nix-ota-invalid-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; overlayOptions.upperOnUpdate = "wipe"; };
        overlay-nix-ota-invalid-reconcile-vm = import ./tests/overlay-nix-ota-invalid-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; overlayOptions.upperOnUpdate = "reconcile"; };
        overlay-nix-ota-invalid-reconcile-degraded-vm = import ./tests/overlay-nix-ota-invalid-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; overlayOptions.upperOnUpdate = "reconcile"; reconcileDegraded = true; };
        # tmpfs upper: nothing persists — the lifecycle degenerates to "wipe
        # for free"; asserts overlay health across the swap only.
        overlay-nix-ota-invalid-tmpfs-vm = import ./tests/overlay-nix-ota-invalid-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; overlayOptions.upperOnUpdate = "wipe"; upperTmpfs = true; };
        runner-store-mode-vm = import ./tests/runner-store-mode-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; };
        # ab-runner-compat-vm: runner clone/build on an appliance-style
        # container (no system nix-daemon) + the non-appliance mode.
        ab-runner-compat-vm = import ./tests/ab-runner-compat-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; };
        # ab-compression-vm targets the ab-image compression matrix.
        ab-compression-vm = import ./tests/ab-compression-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-staging-vm: real run of the staging retain-GC — pre-stage 3 versions +
        # signed manifest → systemctl start nixtache-ab-gc → asserts v1 deleted,
        # v2/v3 kept, SHA256SUMS regenerated, .gpg re-signed + verifies.
        ab-staging-vm = import ./tests/ab-staging-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-deploy-self-vm: self-deploy + gating — local staging, direct
        # sysupdate + idle/busy/forced nixtache-ab-apply against a mocked
        # Forgejo API.
        ab-deploy-self-vm = import ./tests/ab-deploy-self-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-verify-vm: signature verification — a Transfer.Verify=yes
        # target accepts the correctly-signed image (full action.yml run) and
        # rejects wrong-key/tampered/unsigned staging.
        ab-ota-verify-vm = import ./tests/ab-ota-verify-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # auto-update-vm: the auto-update module end-to-end — flake path and
        # ab path.
        auto-update-vm = import ./tests/auto-update-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-rollback-vm: boot-counting rollback — a broken v2 exhausts
        # its tries, the blessed v1 boots, and a fixed v3 still installs.
        ab-ota-rollback-vm = import ./tests/ab-ota-rollback-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-noop-vm: same-version staging installs nothing (no slot
        # write, no boot-entry change, green trigger).
        ab-ota-noop-vm = import ./tests/ab-ota-noop-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-interrupted-vm: sysupdate killed mid-download — the active
        # slot never boots partial content; the next run recovers fully.
        ab-ota-interrupted-vm = import ./tests/ab-ota-interrupted-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-migrate-vm: live→OTA migration — slots provisioned on free
        # space (idempotent), signed first image into the inactive slot, the
        # live generation retained as fallback.
        ab-ota-migrate-vm = import ./tests/ab-ota-migrate-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # ab-ota-migrate-boot-vm: the disk side of migration — a legacy-labeled
        # disk (ESP/nixos) boots the staged UKI: unarmed staging keeps the
        # live-era `default nixos-*` pin (no cutover), armed-with-wrong-labels
        # rolls back safely (boot counting), relabeling to root/boot cuts over
        # with the legacy entry retained as fallback. The override variant
        # mkForce's fileSystems at the legacy labels instead of relabeling.
        ab-ota-migrate-boot-vm = import ./tests/ab-ota-migrate-boot-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        ab-ota-migrate-boot-override-vm = import ./tests/ab-ota-migrate-boot-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; fileSystemsOverride = true; };
        # ab-data-pool-vm: consumer storage outside the slots across swaps —
        # a ZFS pool on a second disk imports and serves state on v1 → v2 →
        # rollback; the overlay-nix upper lives on the pool (OverlayFS-on-ZFS
        # pin). Signed staging.
        ab-data-pool-vm = import ./tests/ab-data-pool-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; };
        # runner-store-swap-vm: R4 un-skipped — the runner's relocated store
        # (clone / overlay) on a REAL appliance across a slot swap: container
        # up on both boots, build works pre/post swap, clone additive,
        # overlay coherent. Signed staging.
        runner-store-swap-clone-vm = import ./tests/runner-store-swap-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; storeMode = "clone"; };
        runner-store-swap-overlay-vm = import ./tests/runner-store-swap-vm.nix { inherit nixpkgs self; system = "x86_64-linux"; appliancePkgs = caPkgs; storeMode = "overlay"; };
      };

      # --- This flake's own option docs -----------------------------------
      # Generated from ALL nixtache modules (runner, deploy-target, ab-image,
      # auto-update, overlay-nix, secrets) via `pkgs.nixosOptionsDoc` so the
      # option reference never drifts from the source. CI builds these and
      # uploads them as artifacts (see .forgejo/workflows/ci.yml).
      #
      #   nix build .#optionsMarkdown   # CommonMark reference
      #   nix build .#optionsJSON       # machine-readable
      #   nix build .#optionsHTML       # browsable standalone HTML
      #
      # We evaluate via the full `nixosSystem` (so every base option the
      # modules touch — `assertions`, `containers`, `systemd`, `services.*`,
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
              self.nixosModules.deploy-target
              self.nixosModules.ab-image
              self.nixosModules.auto-update
              self.nixosModules.overlay-nix
              self.nixosModules.secrets
              { system.stateVersion = lib.trivial.release; }
              # ab-image imports the image-based-appliance profile, which
              # trips the base NixOS no-login assertion (root without a
              # password); satisfy it — same stub the pure-eval tests use.
              { users.users.root.initialPassword = ""; }
            ];
          };
          ownDocs = pkgs.nixosOptionsDoc {
            options = fullEval.options.services.nixtache;
            # Strict by default (warningsAreErrors = true): any nixtache option
            # WITHOUT a description fails the docs build. This enforces the
            # "every mkOption must be documented" rule from AGENTS.md in CI.
          };
          # `ownDocs.optionsJSON` is a directory tree (share/doc/nixos/options.json
          # + brotli + hydra metadata); wrap it into a flat file so the artifact
          # and consumers get a clean `optionsJSON.json`.
          flatOptionsJSON = pkgs.runCommand "options.json" { } ''
            cp ${ownDocs.optionsJSON}/share/doc/nixos/options.json $out
          '';
          # Browsable standalone HTML (like the NixOS manual). nixosOptionsDoc
          # emits CommonMark + AsciiDoc only; render the CommonMark to a
          # self-contained HTML page with pandoc (TOC + syntax highlighting).
          optionsHtml = pkgs.runCommand "options.html"
            {
              nativeBuildInputs = [ pkgs.pandoc ];
            }
            ''
              pandoc ${ownDocs.optionsCommonMark} \
                --standalone --toc --toc-depth=3 \
                --metadata title="nixtache - option reference" \
                --metadata lang=en \
                -o $out
            '';
        in
        {
          optionsMarkdown = ownDocs.optionsCommonMark;
          optionsJSON = flatOptionsJSON;
          optionsHTML = optionsHtml;
          default = self.packages.${system}.optionsMarkdown;
        });
    };
}

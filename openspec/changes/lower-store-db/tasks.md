# Tasks

## 1. ab-image: build-time dump + boot-time loader

- [x] 1.1 Add the validity-record dump generator to `modules/ab-image/` (`pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; }` — its `registration` output is the `nix-store --load-db`-compatible dump, one derivation cached per toplevel) and ship it as a fixed-path `contents` entry of the nix-store partition (`/nixtache/lower-store-db.dump` — NOT `environment.etc`: a toplevel→dump reference is a derivation cycle); verify with a pure-eval pin in `tests/ab-image.nix` that the dump exists in the image config and its records cover the toplevel closure
- [x] 1.2 Add the boot-time loader oneshot (load the running slot's dump into `/nix/var/nix/db` when the DB is absent or the `/var/lib/nixtache/lower-db-version` marker differs from `system.image.version`; additive; updates the marker) and ship `pkgs.nix` in the image; verify with eval pins (unit exists, runs before nix-dependent units) in `tests/ab-image.nix`
- [x] 1.3 Add a boot-time assertion to an overlay-nix VM suite: a lower store path resolves `nix path-info` on first boot with no manual seed; verify `nix build .#vmTests.x86_64-linux.<suite>` passes
- [x] 1.4 Update `doc/user_guide/ota.md` for the shipped DB + loader lifecycle (first boot, swap re-seed, wipe re-seed), linking `openspec/specs/ab-ota/spec.md`; verify the documented behavior matches the implemented units

## 2. overlay-nix: world A shipped

- [x] 2.1 Remove `"none"` from the `services.nixtache.overlay-nix.upperOnUpdate` enum in `modules/overlay-nix/default.nix`, set the default to `"wipe"`, update the option description; verify pure-eval pins assert the new default, that both remaining values configure, and that `upperOnUpdate = "none"` fails evaluation with an error naming the two valid values
- [x] 2.2 Rework `tests/overlay-nix-ota-invalid-vm.nix`: drop the manual DB-seed construct, add a leg pinning shipped lower validity out of the box, keep the hazard/mitigation assertions; verify `nix build .#vmTests.x86_64-linux.overlay-nix-ota-invalid-vm` passes
- [x] 2.3 Rework `tests/overlay-nix-ab-swap-vm.nix` and `tests/overlay-nix-install-vm.nix` for delta installs (assert a path already valid in the lower never lands in the upper); verify both VM suites pass
- [x] 2.4 Update `doc/user_guide/overlay-nix.md`: world-A semantics (delta installs, shipped lower DB), the two-value policy (`"wipe"` default; `"reconcile"` for configurations with a substituter) and the breaking-change migration for configs that never set the option or set `"none"` explicitly, linking `openspec/specs/overlay-nix/spec.md`; verify the guide's stated defaults match the module

## 3. runner: appliance-mode container wiring

- [x] 3.1 Container appliance mode keyed on host `nix.enable = false` in `modules/runner/store.nix`: `nix.enable = false` + `nix.gc.automatic = false` + `nix.optimise.automatic = false` inside the container, module-rendered `environment.etc."nix/nix.conf"` (same settings content), nix CLI in `systemPackages`; verify `tests/runner.nix` appliance-host pins cover all four (extend the suite where missing) via `nix build .#checks.x86_64-linux.runner`
- [x] 3.2 Overlay mode: `overlayStoreUrl` uses `lower-store=local` when the host nix is disabled (keep `daemon` otherwise); clone mode: the standalone scratch-DB seed reads the now-real host DB; verify pure-eval pins for both branches in `tests/runner.nix`
- [ ] 3.3 Unskip `tests/runner-store-swap-vm.nix` (remove the "blocked by lower-store-db" status note) and verify both modes pass on a real appliance: `nix build .#vmTests.x86_64-linux.runner-store-swap-vm` (clone) and the overlay-mode variant
  - Status 2026-10-21: the OVERLAY variant is green under CA (102s: both boots, signed v2 -> slot B, coherent merged view, pre/post-swap builds). The CLONE variant hangs: `nix-daemon-storage` stays `activating` forever — stuck before the copy loop (`/var/log/nix-copy-setup.log` is never created), i.e. in the scratch-DB enumeration; the suite now polls with journal dumps (SEEDPOLL) to capture the error on the next run
- [x] 3.4 Add `runner-store-swap-vm` (both modes) to the `.forgejo/workflows/vmtests.yml` matrix; verify the workflow parses and the matrix entry names match the flake outputs

## 4. Integration

- [x] 4.1 Run `nix flake check --show-trace --all-systems` and `openspec validate lower-store-db --strict`; both green
- [x] 4.2 Update `doc/technical_details/testing.md` (reworked overlay-nix suites, runner-store-swap-vm in the matrix) and `README.md`'s repository map if module responsibilities shifted, linking the touched `openspec/specs/` capabilities; verify every fact still lives in exactly one doc

## 5. CA pivot: content-addressed fleet (post-review revision)

- [x] 5.1 Replace the dump generator in `modules/ab-image/` with `pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; }` (its `registration` output is the dump) plus a build-time guard that fails listing any closure path that is a top-level symlink; delete `lower-store-db-dump.py` and its `__structuredAttrs`/`exportReferencesGraph` machinery; keep the ESP carrier, `15-lower-db` transfer and loader unchanged; rework `tests/ab-image.nix` pins (drop the content-hash pins, pin dump=registration and the symlink guard)
- [x] 5.2 CA wiring: the image eval asserts `pkgs.config.contentAddressedByDefault` (actionable failure naming the nixpkgs config); add `ca-derivations` to the runner container's module-rendered `nix.conf`, the overlay appliance's runtime daemon config and the deploy workflow's build environment; check whether the pinned nix exposes a `content-addressed-by-default` nix.conf setting and prefer it for the container if so; verify with pins in `tests/runner.nix` / `tests/overlay-nix.nix`
- [ ] 5.3 VM fixtures: appliance-image test fixtures import nixpkgs with `contentAddressedByDefault = true`; re-run `overlay-nix-vm`, `overlay-nix-ota-invalid-vm`, `overlay-nix-ab-swap-vm`, `overlay-nix-install-vm` and `runner-store-swap-clone-vm`/`-overlay-vm` (covers the open 3.3) green under CA
  - Status 2026-10-21: 5/6 green under CA after a full local CA world build (`overlay-nix-vm` incl. the symlink-faithful-imaging legs, `overlay-nix-ota-invalid-vm`, `overlay-nix-ab-swap-vm`, `overlay-nix-install-vm`, `runner-store-swap-overlay-vm`); only `runner-store-swap-clone-vm` remains (see 3.3)
- [x] 5.4 Docs: rewrite the "Dump generation" section of `doc/technical_details/lower-store-db.md` for the CA basis (records content-true by construction, the retired python dumper as history, the symlink guard, IA+CA coexistence in one nix-serve); touch `doc/user_guide/ota.md` and `doc/user_guide/overlay-nix.md` with the CA requirement; verify the one-fact-one-file invariant
- [x] 5.5 Re-run `nix flake check --show-trace --all-systems` and `openspec validate lower-store-db --strict` (supersedes the 4.1 run); both green

## 6. Review fixes (post-review revision 2)

- [x] 6.1 Symlink-faithful store imaging: replace `storePaths` on the nix-store partition with a build-time store tree (`modules/ab-image/store-tree.nix`: reads `closureInfo`'s store-paths at build time — no IFD, the tree's outPath is eval-time known; `cp -a --reflink=auto` per real path, `ln -s "$(readlink)"` per top-level symlink path) plus ONE `repartConfig.CopyFiles` from the tree (repart dereferences only the top-level copy source; entry types inside are preserved — `copy_tree_at`/`fd_copy_symlink`); delete the build-time symlink guard from `modules/ab-image/lower-store-db.nix`; works for input-addressed and content-addressed closures alike; rework the pure-eval pins in `tests/ab-image.nix` (CopyFiles wiring replaces `storePaths`, guard pins dropped)
- [x] 6.2 Symlink test coverage: a build-cheap check that builds the store tree with a closure containing a top-level symlink path and asserts the tree preserves it (symlink + target); a VM leg (overlay-nix suite fixture gains `system.extraDependencies = [ <symlink store path> ]`) asserting the booted image ships it as a symlink, `nix path-info` resolves it and its target
- [x] 6.3 ESP ballooning fix in max-disk mode: repart distributes leftover space by Weight and the ESP (no `SizeMaxBytes`, default Weight 1000) takes half of it (measured: 2G image → 1023.5M ESP / 1023.5M root); also repart enforces `ESP_MIN_SIZE_4K` = 260MiB for vfat ESP at 4K fs sectors, silently beating the explicit 200M; pin the ESP fixed at 260M (min=max), fix the `diskSize`/`rootSize` option descriptions (deterministic weight arithmetic, fixed ESP, root takes the remainder); verify pure-eval pins in `tests/ab-image.nix`
- [x] 6.4 `lib.getExe`/`lib.getExe'` pass over `modules/` and `lib/`: replace the `${pkg}/bin/<exe>` pattern (~13 sites: nix-store, nix-daemon, nix, coreutils binaries)
- [x] 6.5 UTF-8 audit of all source files (`modules/`, `tests/`, `lib/`, `.forgejo/`): every file valid UTF-8; replace confusable-class non-ASCII in code files (box-drawing banners, guillemets, ×, ∈, ⇒, ≈, ≥, …, §, en-dash) with ASCII equivalents
- [x] 6.6 Docs explicitness pass: the repo is public — every `doc/*` section must state its full scenario (what breaks, where, why) before the solution, with no implicit agent-session context; rewrite the `lower-store-db.md` intro and its "Consequences wired into the modules" section accordingly (including the nix-master verification that the directory-init workarounds are still required), the ab-image sizing claims, and sweep the remaining docs for session-derived phrasing; add the doc-writing rule to `AGENTS.md`
- [x] 6.7 Re-run `nix flake check --show-trace --all-systems` and `openspec validate lower-store-db --strict`; both green (supersedes 5.5)

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.

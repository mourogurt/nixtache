# Tasks

## 1. Paired slot-store snapshot

- [x] 1.1 Implement one internal snapshot derivation that stages the complete toplevel closure under a scratch-store-compatible `root/nix/store`, preserves top-level symlink paths verbatim and carries the exported path/reference graph without relying on a separate `closureInfo` dump — verify a real input-addressed fixture builds with every source path staged exactly once
- [x] 1.2 Register the staged tree through `nix-store --register-validity` without `--hash-given` in a writable scratch local store with separate temporary state, then emit `lower-db` through `nix-store --dump-db`; assert path-set equality, complete reference closure and successful `nix-store --verify-path` for every staged path — verify the fixture works with `ca-derivations` disabled
- [x] 1.3 Add real-store regression oracles for a deliberately altered staged path, a top-level symlink path and a complete copy into a second scratch store — verify emitted NAR hashes follow staged bytes rather than source registration, symlink identity survives and every copied NAR passes its shipped hash without CA realisations
- [x] 1.4 Reconcile `doc/technical_details/lower-store-db.md` with the paired snapshot, Nix-computed NAR metadata, source-reference trust boundary, caching cost and scratch-store invariants, linking `openspec/specs/ab-ota/spec.md` — verify the document no longer presents CA as required for database/content coherence and retains only current read-only-store constraints

## 2. Image integration and input-addressed build baseline

- [x] 2.1 Replace independent `storeTree` and `lowerStoreDb` image inputs with subpaths of the paired snapshot, remove the `contentAddressedByDefault` assertion and retain the existing ESP dump name, transfer and loader interface; update `tests/ab-image.nix` and `tests/ab-contract.nix` — verify pure evaluation proves both image inputs share one snapshot output and `nix build .#checks.x86_64-linux.ab-image` plus `ab-contract` pass with an ordinary package set
- [x] 2.2 Replace `caPkgsFor` and its package overrides with ordinary input-addressed package-set imports throughout `flake.nix` and appliance fixtures, removing default CA imports rather than adding another addressing-mode option — verify no supported test appliance requires `contentAddressedByDefault` and all affected pure checks evaluate with CA derivation support disabled
- [x] 2.3 Update `doc/user_guide/ota.md` and `README.md` when its overview or repository map changes for the ordinary IA build prerequisites and paired snapshot artifacts, with links to canonical `openspec/specs/` requirements — verify the guide no longer instructs builders to enable CA and documents the unchanged signed artifact flow without deployment-migration chronology

## 3. Overlay and runner IA operation

- [x] 3.1 Remove CA-only feature requirements and command-line feature injections from nixtache-rendered overlay and runner Nix environments while retaining independent `nix-command`, `flakes`, local-overlay and read-only-store requirements; update pure runner/overlay assertions — verify `nix build .#checks.x86_64-linux.overlay-nix` and `runner` pass and the rendered environments operate without `ca-derivations`
- [x] 3.2 Run overlay lower-delta, runtime profile and OTA swap scenarios against IA images with CA support disabled, preserving existing assertions for lower-only reuse, upper writes, database validity and rollback — verify the affected overlay KVM suites pass without changing their functional oracles
- [x] 3.3 Run runner clone and overlay seeding, complete-closure copy and OTA swap scenarios against the snapshot-derived IA lower database — verify affected runner KVM suites pass, including the previous NAR-hash-sensitive clone path, without weakening reference, persistence or restart assertions
- [x] 3.4 Update `doc/user_guide/overlay-nix.md`, affected runner store documentation and `doc/technical_details/testing.md` for IA runtime behavior and the real-store/KVM acceptance layers, linking canonical overlay and runner specs — verify documentation describes current input-addressed behavior and does not claim CA migration support or treat focused fixture success as KVM acceptance

## 4. Integration verification on main

- [x] 4.1 Reconcile all pure-eval expectations and workflow inventory with the IA appliance baseline, then run `nix flake check --show-trace --all-systems`, `nix build .#optionsMarkdown`, `openspec validate snapshot-derived-lower-store-db --strict` and `git diff --check` — verify every supported-system check, option reference, strict validation and whitespace check succeeds on the reviewed tree
- [x] 4.2 Run the complete KVM `vmTests` matrix on a KVM-capable runner at the final reviewed SHA with CA derivation support disabled for appliance scenarios — verify every matrix entry reports PASS and the workflow inventory still exactly matches `vmTests.x86_64-linux`

## Workflow follow-up

- Archive the change after review on `main`, then verify the archived result and maintained-document links.
- Handle any later integration into `slot-scoped-overlay-uppers` as a separate backport, including that change's then-current IFD and slot-preparation assumptions.

# Tasks

## 1. History-preserving moves

- [x] 1.1 `git mv doc/testing.md doc/technical_details/testing.md` (create dir), update the inbound reference in the `flake.nix` comment; verify `grep -rn "doc/testing" --include="*.nix" --include="*.md" .` returns no stale paths
- [x] 1.2 `git mv doc/migration/direct-deploy.md doc/user_guide/migration.md` (create dir, drop empty `doc/migration/`); verify a repo-wide grep for `doc/migration` finds only updated links
- [x] 1.3 `git mv doc/specs/0002-transitive-cache.md doc/specs/0003-smart-gc.md doc/drafts/`, prepend a `> Status: draft — not implemented, awaiting decision` banner to each; verify `ls doc/specs/` shows only implemented specs

## 2. User guide (`doc/user_guide/`)

- [x] 2.1 Write `quickstart.md` merging README "Quickstart" + "Module contract" (canonical options example, consumer commands, workflow wrappers); verify every option name in the example exists via `nix build .#optionsMarkdown && grep` spot-checks
- [x] 2.2 Write `deploy.md` (target map, workflow wrapper, deploy-target module, live vs ab-image, security model) with links to `doc/specs/0001-direct-deploy.md` and `doc/specs/direct-deploy/`; verify each spec link target exists
- [x] 2.3 Write `auto-update.md` (module contract, methods, reboot policy) linking `doc/specs/direct-deploy/09-auto-update.md`; verify option names against the generated options reference
- [x] 2.4 Write `secrets.md` (path-based contract today, `vars`/`providers` target state); verify the described option names match `modules/secrets.nix`
- [x] 2.5 Write `docs-generation.md` (`nixtache.lib.mkDocs` wiring, docs.yml wrapper, tips); verify the documented consumer snippet matches the `lib/mkDocs.nix` argument names
- [x] 2.6 Refresh moved `migration.md`: module/option names current, header links to the deploy specs; verify names against `modules/runner/deploy.nix` option declarations

## 3. Technical details (`doc/technical_details/`)

- [x] 3.1 Write `architecture.md` (workspace diagram, module layout tables for `modules/runner/*` and siblings) as the single canonical home; verify the file lists match `ls modules/runner/ modules/*/`
- [x] 3.2 Write `module-ci-wiring.md` (runner.envs / LoadCredential tables, transport-user vs bot explanation) as the single canonical home; verify env/credential names against `modules/runner/instances.nix` and `ssh.nix`
- [x] 3.3 Write `sandboxing.md` (nspawn/CAP_SYS_ADMIN mechanics, options table, SANDBOX_OK probe, HAS_SANDBOX_CAP legacy note, deploy chicken-and-egg note) as the single canonical home; verify claims against `modules/runner/sandbox.nix` and `.forgejo/actions/sandbox-probe/action.yml`
- [x] 3.4 Write `workflow-mechanics.md` (caller-context checkout, `.nixtache/` action resolution, two-job rendering); verify against `.forgejo/workflows/*.yml`
- [x] 3.5 Refresh moved `testing.md`: suite inventory matches flake.nix exactly (incl. `ab-ota-e2e-erofs/none/percent`, which AGENTS.md previously missed); verify `nix flake show` suite list equals the documented list

## 4. Entry points and rules

- [x] 4.1 Rewrite `README.md` as overview + repository map (modules, workflows, actions, checks/vmTests, doc layers, specs) with one-liners and links, no contract examples, no sha1; verify the map against `flake.nix` exports (no missing/stale entries) and target ≤200 lines
- [x] 4.2 Rewrite `AGENTS.md` per design D5 (repo layout, openspec section with the three rules: docs-task-per-change, self-documenting comments, English; contributor rules kept; consumer content, chicken-and-egg sketch and sha1 removed); verify no section duplicates `doc/user_guide/` content and commands run as written
- [x] 4.3 Add `context` + `rules` to `openspec/config.yaml` per design D6; verify `openspec instructions tasks --change docs-restructure` output includes the English-language and docs-task reminders
- [x] 4.4 Translate the remaining Russian requirements in `openspec/specs/docs/spec.md` (options reference, CI logs, migration plan) to English, keeping requirement names/scenarios semantically identical; verify `openspec show docs --type spec` contains no Russian bodies

## 5. Code phase (zero logic change)

- [x] 5.1 `tests/runner.nix`: replace `runnerToken = ../secrets/runner.env;` with the existing dummy-path pattern, rewrite the header comment accordingly; `git rm secrets/runner.env .sops.yaml`; verify `nix build .#checks.x86_64-linux.runner && cat ./result` prints the ok report and `git ls-files | grep -E "secrets/|\.sops\.yaml"` is empty
- [x] 5.2 Comment sweep `modules/**` per design D3 (self-contained statement first, optional `Background:` spec tail); verify the D3 grep drivers return no bare spec-pointer comments and `nix build .#checks.x86_64-linux.deploy-target .#checks.x86_64-linux.ab-contract` still pass
- [x] 5.3 Comment sweep `flake.nix`, `lib/mkDocs.nix`, `tests/*.nix` headers, `.forgejo/**` comments; verify same grep drivers clean and `nix build .#checks.x86_64-linux.ab-existing .#checks.x86_64-linux.auto-update` still pass
- [ ] 5.4 MANUAL, out of repo: revoke/rotate the runner registration token on the Forgejo instance (file removal does not invalidate it); tick when done — verification is the Forgejo token list, not the repo

## 6. Integration verification

- [x] 6.1 Stale-reference audit: `grep -rn "doc/migration\|doc/testing\.md\|secrets/runner\.env\|doc/specs/000[23]" --include="*.md" --include="*.nix" --include="*.yml" .` returns no hits outside `doc/drafts/` and git history
- [x] 6.2 `nix flake check --show-trace --all-systems` passes; print each `checks.x86_64-linux.<suite>` report
- [x] 6.3 `openspec validate docs-restructure --strict` passes; delta scenarios spot-checked against the tree (three layers exist, no duplication between README/AGENTS/doc, `git ls-files` secret-free)

## 7. Legacy spec corpus archival (openspec canonical)

- [x] 7.1 `git mv doc/specs doc/archive/specs` and `git mv doc/drafts doc/archive/drafts`; write `doc/archive/README.md` stating the corpus is frozen history and pointing to `openspec/specs/` as the canonical continuation; verify `ls doc/archive/` shows `specs/ drafts/ README.md` and no `doc/specs` / `doc/drafts` directories remain
- [x] 7.2 Retarget documentation links: capability-level references in `doc/user_guide/` + `doc/technical_details/` point to `openspec/specs/<capability>/spec.md`; `doc/archive/` is linked only for historical stage detail (09-auto-update, TEST-SPECS); verify every link resolves AND every user_guide/technical_details document describing a spec'd feature contains an `openspec/specs/` link (grep per file)
- [x] 7.3 Update `README.md` layers table and `AGENTS.md` repository-layout + structure-invariant lines: openspec specs are the canonical corpus, `doc/archive/` is frozen, `doc/specs` / `doc/drafts` no longer exist; verify grep for `doc/specs\|doc/drafts` in README.md and AGENTS.md returns nothing
- [x] 7.4 Sweep the remaining `doc/specs` / `doc/drafts` references in code (option descriptions, comment Background tails, assertion messages) to `doc/archive/...` or drop the pointer; verify `grep -rn "doc/specs\|doc/drafts" --include="*.nix" --include="*.yml" .` is empty outside `doc/archive/` and `openspec/`
- [x] 7.5 Re-run audits: stale-reference grep including the archived paths, `nix flake check --show-trace --all-systems`, `openspec validate docs-restructure --strict`; verify all green

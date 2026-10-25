# AGENTS.md - nixtache (contributor contract)

Reusable, vendor-agnostic NixOS CI/CD flake: the Forgejo Actions runner
module, reusable workflows + composite actions, direct deploy, auto-update.
The consumer-facing overview and repository map live in
[`README.md`](README.md) — this file is for agents and humans **working on**
the repo. Workspace-level conventions (shared style, cross-repo layout,
git-infrastructure constraints incl. the sha1 object-format rule) live in
`../AGENTS.md` and are not repeated here.

## Repository layout

```
modules/runner/        the Actions runner module (split by responsibility,
                       merges into one container — see
                       doc/technical_details/architecture.md)
modules/deploy-target/ receiving side of direct deploy
modules/ab-image/      build-time A/B appliance image config
modules/overlay-nix/   writable /nix/store overlay for appliances
modules/auto-update/   unified auto-update channel
modules/secrets.nix    secrets provider abstraction (vars + providers)
lib/mkDocs.nix         consumer docs helper (nixtache.lib.mkDocs)
tests/                 test suites + fixtures (see below)
.forgejo/workflows/    reusable workflows + this repo's own ci.yml + vmtests.yml
.forgejo/actions/      reusable composite actions
doc/user_guide/        consumer-facing functional docs
doc/technical_details/ contributor-facing internals
doc/archive/           frozen legacy spec corpus + drafts (openspec is canonical)
openspec/              OpenSpec specs + changes (see next section)
secrets/               MUST NOT EXIST — this repo stores no secrets
                       (encrypted ones included)
```

`artifacts/` is CI-log scratch space (gitignored).

## OpenSpec in this repo

`openspec/specs/` is the **canonical requirement corpus** — the successor of
the legacy spec corpus, which is frozen under `doc/archive/`.
Requirements live as capabilities; work happens as changes under
`openspec/changes/` (archived ones under `changes/archive/`). Useful commands:

```bash
openspec list --specs                    # capability inventory
openspec list                            # in-flight changes
openspec status --change "<name>" --json # artifact/task status
openspec validate "<name>" --strict
```

Working rules (enforced by convention + `openspec/config.yaml`):

1. **Documentation task per change.** Every change touching functional
   surfaces (modules, workflows, actions, options) MUST include a task to
   update `README.md` (when the map/overview changes) and the affected
   `doc/user_guide/` / `doc/technical_details/` documents, with links to the
   relevant openspec specs (`openspec/specs/`).
2. **English.** All documentation, specs and change artifacts are written in
   English (frozen `doc/archive/` content and the not-yet-translated
   `direct-deploy` / `deploy-user` specs are the only exceptions).
3. **Self-documenting comments** (see below).
4. **Document current behavior, not development progress.** Maintained docs,
   option descriptions and canonical specs MUST describe present contracts,
   invariants and operational risks — not what was fixed, rewritten,
   re-verified or remains in flight. Commit messages, OpenSpec change
   artifacts and `doc/archive/` own chronology. Retain a failure scenario
   only when it explains a current risk, constraint or recovery procedure;
   never keep a resolved-bug story just to explain a patch. Actionable
   migration and version-compatibility notes are allowed.
5. Think carefully what comes in each document of `doc/` directory:
   don't duplicate information; include only what that document needs.
6. Before expanding a doc, avoid bloat and restructure where necessary.
7. **Docs are written for public-repo readers.** The repository is public:
   a reader has no access to the debugging session, review thread or
   agent conversation in which a problem was found. Never describe only
   the solution of a problem whose statement lives elsewhere — each
   `doc/*` section must carry its full scenario explicitly: what breaks,
   on which surface, with what symptom, and only then how it is solved.
   A pointer to a spec/issue may follow, never replace, that statement.

Docs structure invariant: every fact lives in exactly ONE file; everything
else links to it. README = overview/map; user_guide = functional;
technical_details = internals; openspec specs = canonical requirements;
doc/archive = frozen history.

## Contributor rules

### Nix style

Follows the workspace conventions (`../AGENTS.md`): 2-space indent,
kebab-case files, camelCase vars, `{ config, lib, pkgs, ... }:` signature,
`mkIf`/`mkMerge`/`mkOption` with `defaultText`, `lib.literalMD`/
`lib.literalExpression` for non-trivial defaults.

**No changelog comments in code** (Nix, YAML workflows/actions, bash alike).
Explanations of *why a line was added / removed / changed* go in the commit
message, never inline; inline comments document non-obvious *logic* only, and
a deletion stays a deletion. See workspace `AGENTS.md` → "Comments & commit
messages".

### Comments must be self-documenting

A code comment must be understandable **without opening any other document**:
state the invariant, constraint or behaviour in the comment itself. A
reference to a spec section or scenario code (`spec §11.7`, `A2`, `S2`, …)
may only FOLLOW a self-contained explanation, never replace it. A comment
consisting solely of a spec pointer is a bug.

### Terminology

`doc/GLOSSARY.md` is the canonical domain vocabulary. Check it before
introducing or renaming a domain term; when a change resolves or sharpens a
term, update the glossary in the same change. Terms are concepts — option
names and file paths stay in the docs that own them, not in the glossary.

### Every `mkOption` MUST have a `description` (enforced in CI)

Never commit an `mkOption` without a `description` (submodule options
included). `nixosOptionsDoc` for this flake's own
`packages.optionsMarkdown`/`optionsJSON`/`optionsHTML` runs with
`warningsAreErrors = true`, so an undocumented option BREAKS the docs build
in `ci.yml`. `mkEnableOption` auto-generates one and is exempt. Consumers opt
into the same strictness via `nixtache.lib.mkDocs { docStrictMode = true; }`.

### Every option MUST be covered by a test

Every consumer-facing `mkOption` (and each meaningful behaviour of its
`config`) gets at least one assertion in `tests/`. Options without tests are
unfinished. The pattern to follow is `tests/runner.nix` (pure-eval scenarios:
build a `nixosSystem` with specific option values, assert on `config.*`);
`tests/mkDocs.nix` is the analogue for `lib/`. Strategy, suite inventory and
the checks-vs-vmTests split: `doc/technical_details/testing.md`.

New test files MUST be wired into `flake.nix`: pure-eval suites into
`checks.<system>` (must stay build-cheap — `nix flake check` builds them
every CI run), KVM/runNixOSTest suites into `vmTests.x86_64-linux` (NOT a
checked output; CI runs them via `vmtests.yml` on a KVM-capable runner,
manually via `nix build .#vmTests.…`).

## Commands

```bash
# Validate this flake
nix flake check --show-trace --all-systems

# Evaluate the runner module standalone (no host needed) — sanity check
nix-instantiate --parse modules/runner/default.nix > /dev/null && echo OK

# Build this flake's own generated option reference
nix build .#optionsMarkdown && cat ./result

# One pure-eval suite's report
nix build .#checks.x86_64-linux.runner && cat ./result

# KVM-only VM suites (KVM host, not run by flake check)
nix build .#vmTests.x86_64-linux.<suite>
```

Runner sandboxing defaults to `enableSandbox = false`; CI uses the runtime
`sandbox-probe` / `SANDBOX_OK` result to decide whether to add `--no-sandbox`.
Runner-side mechanics (sandbox probe, credential wiring, reusable-workflow
resolution) are documented once in `doc/technical_details/` — `sandboxing.md`,
`module-ci-wiring.md`, `workflow-mechanics.md`. Workflow and action inventories
live in the [README repository map](README.md#repository-map).

## TODO / out of scope

- **Secret provider implementations.** The provider abstraction
  (`services.nixtache.secrets.{vars,providers}`) is in place — see
  `modules/secrets.nix` and `doc/user_guide/secrets.md`. Concrete provider
  modules (`ssh`, `forgejo`, `vault` as primary, `systemd`) land
  incrementally, each just appending to `vars`.
- Translation of the remaining Russian specs (`direct-deploy`, `deploy-user`)
  to English.

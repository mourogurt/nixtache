# Proposal

## Why

The repository has accumulated vibe-coded residue: the same facts are
duplicated across README (547 lines), AGENTS.md (417 lines) and the
workspace-level AGENTS (sha1 alone has 3 copies); the three audiences
(consumer / contributor / repo admin) are smeared over the files with no
ownership; AGENTS.md carries a ~90-line superseded historical sketch and does
not mention openspec/ at all; an unused sops-encrypted token
(`secrets/runner.env`) is committed to git although it is needed only as a
dummy path in a pure-eval test; ~30 code comments are bare pointers to spec
sections instead of explanations. A reader cannot find the canonical place
for a fact, and the repo contradicts its own "stores no secrets" claim.

## What Changes

- **README.md is rewritten** as a short overview (~150 lines): what nixtache
  is, a repository map, a pointer to the quickstart. Full documentation moves
  into `doc/`.
- **New `doc/` structure**: `doc/user_guide/` (consumer-facing functional
  docs: quickstart, direct deploy, migration, auto-update — each linking to
  specs) and `doc/technical_details/` (module layout, sandbox internals,
  module→CI wiring, testing, reusable-workflow mechanics). The canonical
  requirement corpus going forward is `openspec/specs/` (capabilities),
  not `doc/`.
- **Docs link to openspec specs**: `doc/user_guide/` and
  `doc/technical_details/` reference the openspec capabilities
  (`openspec/specs/<capability>/spec.md`) as the requirement source;
  archived legacy specs are linked only as historical deep-dives.
- **AGENTS.md is rewritten** as a contributor contract: style, testing rules,
  an openspec section, repository layout. Removed: consumer content, the
  historical "chicken-and-egg" sketch, sha1 duplication. Added rules: (a)
  every openspec change must include a task to update README + user_guide +
  technical_details; (b) code comments must be self-documenting.
- **`openspec/config.yaml`**: rule (a) is also recorded in `rules.tasks`;
  the working language (English) is recorded in `context` and per-artifact
  `rules`.
- **Legacy spec corpus is archived**: `doc/specs/` and `doc/drafts/` are
  legacy — from this change on only openspec specs are maintained. Both move
  to `doc/archive/{specs,drafts}/` (git mv, content frozen) with a freeze
  note pointing to `openspec/specs/`; the unimplemented drafts `0002-*` /
  `0003-*` keep their status banners there.
- **Comments pass with zero logic change**: comments in `modules/`, `lib/`,
  `flake.nix`, `tests/` headers that reference "spec §N" / scenario codes
  (A2, §11.7, S2, …) are rewritten as self-contained statements; a spec link
  may follow the explanation as a supplement, never replace it.
- **Secrets are removed from the repo**: `secrets/runner.env` and
  `.sops.yaml` are deleted; `tests/runner.nix` uses a dummy path
  (eval-equivalent: the module never reads tokenFile at eval time).
  Rotation/revocation of the token on the Forgejo side is a manual
  out-of-repo step, recorded in tasks.
- **sha1 deduplication**: the section is removed from README and AGENTS.md;
  the canonical copy already lives in `../AGENTS.md` (workspace), which this
  change does NOT touch.
- **English as the working language**: all new/rewritten documentation,
  specs and change artifacts are written in English; the rule is enforced
  via AGENTS.md and `openspec/config.yaml`. The remaining Russian
  requirements of the `docs` capability are translated during this change;
  the archived legacy corpus stays as-is (frozen), and the openspec specs
  `direct-deploy` / `deploy-user` are left in Russian for now.
- **Scope-placement audit** is recorded in design.md (what lives where and
  why); the agent directories (`.opencode/`, `.agents/`, `.pi/`, `.zcode/`,
  `.kimi-code/`) are not touched — a separate decision outside this change.
- **Zero functional delta**: `modules/`, `lib/`, `.forgejo/` get comment-only
  edits; every change is eval-identical, `nix flake check` stays green.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `docs`: the README requirement ("document the whole export surface") is
  replaced by an overview-level one; the AGENTS.md requirement is replaced by
  a contributor-contract scope plus openspec awareness; the spec-corpus
  requirement is replaced by "canonical spec corpus lives in openspec"
  (legacy corpus archived). New requirements: three-layer documentation
  structure with a single-source invariant and openspec-spec links, mandatory
  documentation task in every change, self-documenting code comments, no
  secrets in the repository, English as the documentation language.

## Impact

- Files: `README.md`, `AGENTS.md`, `openspec/config.yaml`,
  `openspec/specs/docs/spec.md` (translate the remaining Russian
  requirements), `doc/**` (moves + new files: user_guide/technical_details
  written; `doc/specs` → `doc/archive/specs` and `doc/drafts` →
  `doc/archive/drafts` with a freeze README; content otherwise not edited),
  doc links retargeted to `openspec/specs/`, `secrets/` + `.sops.yaml`
  (deleted), `tests/runner.nix` (one line + comment), comments in
  `modules/**/*.nix`, `lib/mkDocs.nix`, `flake.nix`, `tests/*.nix` headers,
  `.forgejo/**` comments where needed.
- Functionality: unchanged (eval-identical edits). `nix flake check`, all
  `checks.*` suites and the CI pipeline keep working without logic edits.
- Out of repo (manual steps, not code): rotate the runner token on Forgejo;
  refreshing `../AGENTS.md` is a separate task, not part of this change.

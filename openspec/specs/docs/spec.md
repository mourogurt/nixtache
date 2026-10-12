# docs Specification

## Purpose

Documenting the implemented surface of the nixtache flake: user-facing docs
(README/AGENTS), the generated option reference, CI reports, and keeping
this spec corpus in sync with the code.

## Requirements

### Requirement: Generated option reference covers all modules

`packages.optionsMarkdown`/`optionsJSON`/`optionsHTML` MUST be generated
from an eval that includes ALL nixtache modules (the whole
`services.nixtache.*` prefix: runner, deploy-target, ab-image, auto-update —
options of overlay-nix/store outside the prefix are pinned explicitly), in
strict mode (a missing description fails the docs build).

#### Scenario: The reference contains deploy-target options

- **WHEN** `nix build .#optionsMarkdown` is built
- **THEN** the reference contains `services.nixtache.deploy-target.*`,
  `services.nixtache.runner.deploy.targets.*` and
  `services.nixtache.auto-update.*` options — not only runner

### Requirement: CI log shows every test suite

`ci.yml` MUST print the reports (ok/FAIL tables) of every `checks.<system>`
suite that `nix flake check` builds — not only runner; file headers MUST NOT
claim "intentionally red" / "the module does not exist" for modules that have
already landed.

#### Scenario: Each suite's report is visible in the log

- **WHEN** the CI job finishes
- **THEN** the log contains separate report blocks for the runner,
  deploy-target, ab-image, ab-existing, ab-contract, auto-update and mkDocs
  suites

### Requirement: Consumer migration plan

The repository MUST contain a migration document for nixtache consumers:
adopting the deploy feature on an existing flake (target map, deploy keys,
receiving module, workflow wrappers), moving from `system.autoUpgrade` to
auto-update, and the BREAKING changes of that change (removal of
`deployUser.nixTrust`, the system deploy user).

#### Scenario: A consumer can upgrade by following the document

- **WHEN** a consumer on a previous nixtache version bumps the input and follows the migration document
- **THEN** every BREAKING change is listed with an action (what to remove, what replaces it) and the final configuration passes `nix flake check`

### Requirement: Three-layer documentation structure

Repository documentation MUST consist of three layers with distinct
audiences: `README.md` (overview entry point), `doc/user_guide/`
(consumer-facing functional docs: onboarding, direct deploy, migration,
auto-update) and `doc/technical_details/` (contributor-facing technical
docs: module layout, sandbox internals, module→CI wiring, testing,
reusable-workflow mechanics). The canonical requirement corpus is
`openspec/specs/` (capabilities); it is not a doc layer. Invariant: every
fact MUST live in exactly one file; every other location links to it instead
of copying it. `doc/user_guide/` and `doc/technical_details/` MUST link to
the relevant openspec specs (`openspec/specs/<capability>/spec.md`);
archived legacy specs (`doc/archive/`) MAY be linked additionally as
historical context. Repository-infrastructure constraints (sha1) MUST NOT
be duplicated in project docs — their canonical home is outside the
repository (the workspace AGENTS).

#### Scenario: Reader reaches a detail in two hops

- **WHEN** a reader opens README.md with any goal (adopt, contribute, understand)
- **THEN** README provides the overview and a map, and the reader reaches the detail via a link into `doc/user_guide/` or `doc/technical_details/` in at most two hops

#### Scenario: A fact has a single canonical place

- **WHEN** a fact (e.g. sandbox behaviour or a module contract) is mentioned in several documents
- **THEN** the full text lives in exactly one file and the other mentions link to it; textual copies do not exist

#### Scenario: Docs link to openspec specs

- **WHEN** a document in `doc/user_guide/` or `doc/technical_details/` describes a feature covered by an openspec capability
- **THEN** the document links the corresponding `openspec/specs/<capability>/spec.md`; links into `doc/archive/` appear only as historical supplements

### Requirement: README is an overview entry point

README.md MUST be a short overview: what nixtache is, what a consumer
imports, a repository map (modules, workflows, actions, docs, specs) with
one-line descriptions and pointers into `doc/user_guide/`,
`doc/technical_details/` and the openspec specs (`openspec/specs/`). README
MUST NOT carry full contract examples, internal mechanics or
repository-infrastructure constraints — only links.

#### Scenario: README stays an overview

- **WHEN** README.md is compared against `doc/user_guide/` and `doc/technical_details/`
- **THEN** every README section is either overview or a link; no content of those directories is duplicated

#### Scenario: The repository map is accurate

- **WHEN** flake.nix exports `nixosModules.{runner,deploy-target,ab-image,overlay-nix,auto-update,secrets}`, workflows and actions
- **THEN** the README map lists them with one-line descriptions; there are no missing or stale entries

### Requirement: Mandatory documentation task in every change

Every openspec change of this repository MUST include a task in `tasks.md`
to update the documentation of the surfaces it touches: README.md (when the
map/overview changes) + `doc/user_guide/` + `doc/technical_details/`. The
rule MUST be recorded in AGENTS.md and in `openspec/config.yaml`
(`rules.tasks`) so the CLI reminds about it while artifacts are created.

#### Scenario: A new change contains a documentation task

- **WHEN** a change touching functional surfaces (modules, workflows, actions, options) is created
- **THEN** its tasks.md contains a task to update README and the affected `doc/user_guide/` / `doc/technical_details/` documents with links to specs

#### Scenario: The rule is machine-readable

- **WHEN** `openspec instructions tasks --change <name>` runs
- **THEN** the output includes the reminder about the mandatory documentation task (from `rules.tasks` in `openspec/config.yaml`)

### Requirement: Self-documenting code comments

Comments in code (`modules/`, `lib/`, `flake.nix`, `tests/`, `.forgejo/`)
MUST be self-contained: they explain the invariant, constraint or behaviour
so that a reader understands what happens without opening external
documents. A spec link is allowed only as a supplement after a
self-contained explanation; a comment consisting solely of a spec/section
reference or scenario codes (§N, A2, S2, …) without an explanation is not
acceptable. The rule MUST be recorded in AGENTS.md.

#### Scenario: A comment is understandable without the spec

- **WHEN** a reader encounters a comment that previously read as "spec §11.7" or a bare scenario code
- **THEN** the comment states the invariant/behaviour itself; a spec link may follow the explanation

#### Scenario: No bare spec pointers

- **WHEN** the repository code is searched for comments containing only references like `doc/specs/... §N`, `spec §N` or scenario codes without explanatory text
- **THEN** no such comments exist

### Requirement: The repository stores no secrets

The git content of the repository MUST NOT include secrets — including
encrypted ones (sops/age) — or their decryption configuration (`.sops.yaml`,
`secrets/`). Tests that need a secret path MUST use dummy paths: the module
never reads secret files at evaluation time. This makes the README claim
"nixtache never stores secrets" true of the actual repository content.

#### Scenario: No secrets or sops configuration in git

- **WHEN** `git ls-files` is checked
- **THEN** no `secrets/**` or `.sops.yaml` entries are tracked

#### Scenario: Tests do not depend on a real secret

- **WHEN** the pure-eval suites (`checks.*`) are built after replacing `secrets/runner.env` with a dummy path
- **THEN** every suite passes with its assertions unchanged

### Requirement: Documentation is written in English

All documentation, specs and change artifacts of this repository MUST be
written in English: README, `doc/**`, AGENTS.md, openspec specs and change
artifacts. Russian is acceptable only in frozen historical material — the
archived legacy corpus under `doc/archive/` — and, until a dedicated
translation sweep, in the not-yet-translated openspec specs
(`direct-deploy`, `deploy-user`). The rule MUST be recorded in AGENTS.md
and in `openspec/config.yaml` (`context` + per-artifact `rules`).

#### Scenario: New docs are English

- **WHEN** a new or rewritten document, spec or change artifact is created
- **THEN** it is written in English

#### Scenario: The language rule is machine-readable

- **WHEN** `openspec instructions <artifact> --change <name>` runs
- **THEN** the output reminds that artifacts are written in English (from `rules` in `openspec/config.yaml`)

### Requirement: AGENTS.md is a contributor contract reflecting reality

AGENTS.md MUST reflect the current state: the complete list of
modules/workflows/actions, the correct `enableSandbox = false` default in
every mention, the sandbox-probe/SANDBOX_OK description, and no claims like
"deploy is not implemented" / "checks = runner only". Internal
contradictions (a sandbox default in a table vs a snippet) are not
acceptable. AGENTS.md MUST be a contributor contract, not consumer
documentation: consumer content and contract examples duplicating
`doc/user_guide/` are not allowed (links instead of copies); historical or
superseded sketches are not allowed (their place is `doc/archive/drafts/`).
AGENTS.md MUST contain an openspec section describing how specs and changes
are organized in this repository, and MUST state the rules "mandatory
documentation task in every change", "self-documenting code comments" and
"documentation is written in English".

#### Scenario: AGENTS.md contains no stale facts

- **WHEN** AGENTS.md is cross-checked against flake.nix and the module code
- **THEN** every claim about exports, defaults and CI behaviour is confirmed by code; the TODO section contains no already-implemented items

#### Scenario: AGENTS.md does not duplicate consumer docs

- **WHEN** AGENTS.md is compared with README.md and `doc/user_guide/`
- **THEN** contract examples and functional descriptions are not copied; they are linked

#### Scenario: AGENTS.md has an openspec section

- **WHEN** a contributor opens AGENTS.md
- **THEN** they find the openspec layout for this repo (canonical specs, changes, archive), the statement that `openspec/specs/` is the canonical requirement corpus replacing the archived `doc/archive/` legacy, and the three rules: documentation task per change, self-documenting comments, English as the working language

### Requirement: Canonical spec corpus lives in openspec

`openspec/specs/` is the canonical, maintained requirement corpus: its
capabilities reflect the implemented behaviour of the flake, and changes to
functional surfaces update them through openspec changes. The legacy spec
corpus and the drafts are historical: they MUST live
under `doc/archive/{specs,drafts}/` (frozen content, not kept in sync) with
an explicit freeze note pointing to `openspec/specs/`. The unimplemented
drafts 0002 (transitive cache) and 0003 (smart GC) keep their
"not implemented, awaiting decision" status notes in the archive.

#### Scenario: Capability inventory reflects reality

- **WHEN** a contributor reads `openspec/specs/`
- **THEN** the capability set corresponds to the implemented functional surface (e.g. direct-deploy, deploy-user, docs), with no capability describing unshipped behaviour

#### Scenario: The archive is marked as frozen

- **WHEN** a reader opens `doc/archive/`
- **THEN** a README states that the corpus is frozen history and points to `openspec/specs/` as the canonical continuation; nothing in the repo references the archived material as active documentation

#### Scenario: Unimplemented drafts stay isolated

- **WHEN** `doc/archive/drafts/` is opened
- **THEN** 0002 (transitive cache) and 0003 (smart GC) carry their status notes ("draft — not implemented, awaiting decision")

# docs Specification

## Purpose

Documenting the implemented surface of the nixtache flake: the README
overview, consumer guide, contributor documentation and contract, generated
option reference, CI reports, and this spec corpus.

## Requirements

### Requirement: Generated option reference covers all modules

`packages.optionsMarkdown`/`optionsJSON`/`optionsHTML` MUST be generated
from an eval that includes ALL nixtache modules under `services.nixtache.*`:
runner, deploy-target, ab-image, overlay-nix, auto-update and secrets. Strict
mode MUST make a missing description fail the docs build.

#### Scenario: The reference contains deploy-target options

- **WHEN** `nix build .#optionsMarkdown` is built
- **THEN** the reference contains `services.nixtache.deploy-target.*`,
  `services.nixtache.runner.deploy.targets.*` and
  `services.nixtache.auto-update.*` options — not only runner

### Requirement: CI log shows every test suite

`ci.yml` MUST print the reports (ok/FAIL tables) of every `checks.<system>`
suite that `nix flake check` builds — not only runner. Test headers MUST
describe current behavior and MUST NOT claim intentional failure or missing
modules for implemented functionality.

#### Scenario: Each suite's report is visible in the log

- **WHEN** the CI job finishes
- **THEN** the log contains a separate report block for every suite registered
  in `checks.<system>`

### Requirement: Consumer migration plan

The repository MUST NOT maintain a standalone migration document. Actionable
upgrade guidance MUST live inline in the relevant user-guide pages; historical
BREAKING-change records MUST remain under `doc/archive/`. Live documents and
runtime messages MUST NOT link to the retired `doc/user_guide/migration.md`.

#### Scenario: A consumer can upgrade by following the document

- **WHEN** a consumer on a previous nixtache version bumps the input and
  follows the user guide (deploy + auto-update pages, plus the archived
  BREAKING history when crossing that boundary)
- **THEN** every BREAKING change is listed with an action (what to remove,
  what replaces it) at exactly one canonical place, and the final
  configuration passes `nix flake check`

#### Scenario: No dangling migration references

- **WHEN** the repository is searched for references to
  `doc/user_guide/migration.md` (docs, module option descriptions,
  assertion messages, README)
- **THEN** no live reference remains; the retired sections are either
  covered by their canonical pages or archived with a freeze note

### Requirement: Three-layer documentation structure

Documentation MUST use three layers: README overview, consumer
`doc/user_guide/`, and contributor `doc/technical_details/`. `openspec/specs/`
is the canonical requirement corpus, not a doc layer. Every fact MUST have one
canonical file; other locations link instead of copying. Feature docs MUST
link relevant specs, archives are historical supplements only, and the README
map MUST link every module. Workspace-infrastructure constraints MUST NOT be
duplicated here.

#### Scenario: Reader reaches a detail in two hops

- **WHEN** a reader opens README.md with any goal (adopt, contribute, understand)
- **THEN** README provides the overview and a map, and the reader reaches the detail via a link into `doc/user_guide/` or `doc/technical_details/` in at most two hops

#### Scenario: A fact has a single canonical place

- **WHEN** a fact (e.g. sandbox behaviour or a module contract) is mentioned in several documents
- **THEN** the full text lives in exactly one file and the other mentions link to it; textual copies do not exist

#### Scenario: Docs link to openspec specs

- **WHEN** a document in `doc/user_guide/` or `doc/technical_details/` describes a feature covered by an openspec capability
- **THEN** the document links the corresponding `openspec/specs/<capability>/spec.md`; links into `doc/archive/` appear only as historical supplements

#### Scenario: OTA and overlay have canonical user-guide pages

- **WHEN** a reader wants to deploy or troubleshoot the OTA route or the
  overlay store
- **THEN** dedicated `doc/user_guide/ota.md` and
  `doc/user_guide/overlay-nix.md` pages exist, the README module map links
  to them, and both link the `ab-ota` and `overlay-nix` openspec
  capabilities as their canonical requirements

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

Maintained documentation, specs and change artifacts MUST be written in
English. Russian is allowed only in frozen `doc/archive/` material and the
not-yet-translated `direct-deploy` / `deploy-user` specs. The rule MUST be
recorded in AGENTS.md and `openspec/config.yaml`.

#### Scenario: New docs are English

- **WHEN** a new or rewritten document, spec or change artifact is created
- **THEN** it is written in English

#### Scenario: The language rule is machine-readable

- **WHEN** `openspec instructions <artifact> --change <name>` runs
- **THEN** the output reminds that artifacts are written in English (from `rules` in `openspec/config.yaml`)

### Requirement: AGENTS.md is a contributor contract reflecting reality

AGENTS.md MUST be a current contributor contract: list modules, link the
README workflow/action inventories, state `enableSandbox = false` and the
`SANDBOX_OK` probe, and describe the OpenSpec layout and rules for documentation
tasks, self-contained comments, English and current-behavior docs. Stale status,
consumer-guide duplication and superseded sketches MUST NOT appear there.

#### Scenario: AGENTS.md contains no stale facts

- **WHEN** AGENTS.md is cross-checked against flake.nix and the module code
- **THEN** every claim about exports, defaults and CI behaviour is confirmed by code; the TODO section contains no already-implemented items

#### Scenario: AGENTS.md does not duplicate consumer docs

- **WHEN** AGENTS.md is compared with README.md and `doc/user_guide/`
- **THEN** contract examples and functional descriptions are not copied; they are linked

#### Scenario: AGENTS.md has an openspec section

- **WHEN** a contributor opens AGENTS.md
- **THEN** they find the openspec layout for this repo (canonical specs, changes, archive), the statement that `openspec/specs/` is the canonical requirement corpus replacing the archived `doc/archive/` legacy, and the rules for documentation tasks on functional changes, self-documenting comments, English, and current-behavior documentation

### Requirement: Canonical spec corpus lives in openspec

`openspec/specs/` MUST be the canonical, maintained requirement corpus;
functional changes update it through OpenSpec changes. Legacy specs and drafts
MUST remain frozen under `doc/archive/{specs,drafts}/`, with a freeze note
pointing to the canonical corpus. Unimplemented drafts 0002 and 0003 MUST keep
their "not implemented, awaiting decision" status notes.

#### Scenario: Capability inventory reflects reality

- **WHEN** a contributor reads `openspec/specs/`
- **THEN** the capability set corresponds to the implemented functional surface (e.g. direct-deploy, deploy-user, docs), with no capability describing unshipped behaviour

#### Scenario: The archive is marked as frozen

- **WHEN** a reader opens `doc/archive/`
- **THEN** a README states that the corpus is frozen history and points to `openspec/specs/` as the canonical continuation; nothing in the repo references the archived material as active documentation

#### Scenario: Unimplemented drafts stay isolated

- **WHEN** `doc/archive/drafts/` is opened
- **THEN** 0002 (transitive cache) and 0003 (smart GC) carry their status notes ("draft — not implemented, awaiting decision")

### Requirement: VM test suites run in CI on a KVM-capable runner

The repository MUST provide a CI workflow that runs the `vmTests`
inventory (the KVM-only VM suites `nix flake check` skips) on a
KVM-capable runner, triggerable manually and on a schedule. The workflow
MUST print each suite's report (ok/FAIL lines) to the job log and fail
naming the failing suites; it MUST NOT run on the nspawn-only checks
runner.

#### Scenario: Scheduled run executes the suite matrix

- **WHEN** the VM workflow runs (manual dispatch or schedule) on a runner
  with KVM and the `nixos-test` system feature
- **THEN** every suite in the matrix builds, its report block is visible
  in the job log, and the job result reflects the suites' pass/fail state

#### Scenario: KVM prerequisites are documented for operators

- **WHEN** an operator deploys a runner for the VM workflow
- **THEN** the documentation states the prerequisites: `/dev/kvm` exposed
  to the runner environment and `kvm` + `nixos-test` present in the nix
  `system-features` the runner propagates to jobs

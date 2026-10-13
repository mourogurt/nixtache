# Spec Delta

## MODIFIED Requirements

### Requirement: Consumer migration plan

The repository MUST NOT maintain a standalone migration document. Current
upgrade guidance lives inline in the user guide where the feature is
documented: the `system.autoUpgrade` → auto-update walkthrough in the
auto-update guide, the protocol-drift rollout order (module first, then
action, with the `sshGate = "restrict"` transition hatch) in the deploy
guide. Historical BREAKING-change records (the `finalize-direct-deploy`
table and its upgrade order) are frozen history and MUST live under
`doc/archive/`. No live document may link to a `migration.md` that no
longer exists.

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

Repository documentation MUST consist of three layers with distinct
audiences: `README.md` (overview entry point), `doc/user_guide/`
(consumer-facing functional docs: onboarding, direct deploy, OTA (A/B
updates), the overlay store, auto-update, secrets, docs generation) and
`doc/technical_details/` (contributor-facing technical docs: module
layout, sandbox internals, module→CI wiring, testing, reusable-workflow
mechanics). The canonical requirement corpus is `openspec/specs/`
(capabilities); it is not a doc layer. Invariant: every fact MUST live in
exactly one file; every other location links to it instead of copying it.
`doc/user_guide/` and `doc/technical_details/` MUST link to the relevant
openspec specs (`openspec/specs/<capability>/spec.md`); archived legacy
specs (`doc/archive/`) MAY be linked additionally as historical context.
Repository-infrastructure constraints (sha1) MUST NOT be duplicated in
project docs — their canonical home is outside the repository (the
workspace AGENTS). The README repository map MUST link every module to its
user-guide page (no linkless module rows).

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
  to them, and both link the `ab-ota` / `overlay-nix` openspec
  capabilities as their canonical requirements

## ADDED Requirements

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

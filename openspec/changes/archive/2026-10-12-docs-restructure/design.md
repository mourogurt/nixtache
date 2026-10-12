# Design

## Context

See proposal.md (Why) for motivation. Current state that shapes the design:

- Doc corpus: `README.md` (547 lines) + `AGENTS.md` (417 lines) +
  `../AGENTS.md` (workspace) + `doc/` (~9100 lines incl. specs). Facts are
  duplicated 2–3×: sha1 (3 copies), module-contract example, module→CI wiring
  table, sandbox section, workflow mechanics.
- `doc/` today: `specs/` (0001 + `direct-deploy/*` + unimplemented drafts
  0002/0003), `migration/direct-deploy.md`, `testing.md`, `drafts/`.
- OpenSpec: 3 live capabilities (`deploy-user`, `direct-deploy`, `docs`), all
  written in Russian; config.yaml has no `context`/`rules` filled in.
- Stray tracked files: `secrets/runner.env` (sops-encrypted token, referenced
  ONLY by `tests/runner.nix:39` as an eval-time path), `.sops.yaml`, five
  agent-tool dirs (81 files).
- ~30 code comments referencing spec sections/codes instead of explaining.
- Link surface to preserve: `flake.nix:55` → `doc/testing.md`; README/AGENTS
  → `doc/migration/…`, `doc/specs/…`; `doc/specs/0001` → `doc/drafts/…`
  (those inbound links inside `doc/specs/` stay valid — drafts dir is not
  renamed).

## Goals / Non-Goals

**Goals:**

- One canonical place per fact; three doc layers with clear audiences.
- Zero functional delta: comment-only edits in code; eval-identical test
  change for the token removal; CI stays green.
- English as the enforced working language, recorded machine-readably.
- A scope-placement audit recorded (design-level) so "is X in the right
  place?" has an answer.

**Non-Goals:**

- Editing `../AGENTS.md` (workspace) — separate task; the sha1 canonical copy
  already exists there, so deduplication needs no workspace edit.
- Translating the `direct-deploy` / `deploy-user` specs (deferred sweep; only
  the `docs` capability ends up fully English in this change).
- Editing the content of implemented specs in `doc/specs/` (moves only).
- Deciding the fate of `.opencode/ .agents/ .pi/ .zcode/ .kimi-code/`
  (audit notes them; separate decision).
- Any nix/yaml logic change, however small.

## Decisions

### D1: Target tree and old→new mapping

```
README.md                       overview + repo map (the index)
doc/user_guide/                 consumer, functional
  quickstart.md                 input, import, options, workflows wrappers
  deploy.md                     direct deploy + security model
  auto-update.md                auto-update module
  secrets.md                    path-based contract + provider abstraction
  docs-generation.md            mkDocs wiring + docs.yml wrapper
  migration.md                  consumer migration guide (was doc/migration/)
doc/technical_details/          contributor, internals
  architecture.md               diagrams + module layout tables
  module-ci-wiring.md           runner.envs / LoadCredential tables
  sandboxing.md                 nspawn sandbox mechanics + SANDBOX_OK probe
  workflow-mechanics.md         reusable workflow/action resolution
  testing.md                    was doc/testing.md
openspec/specs/                 canonical requirement corpus (capabilities)
doc/archive/specs/              was doc/specs/ — frozen legacy design record
doc/archive/drafts/             was doc/drafts/ + 0002/0003 — frozen drafts
doc/archive/README.md           freeze note → canonical is openspec/specs/
```

No per-directory index files: the README map is the single index (avoids a
second place to rot). Link policy: `doc/user_guide/` and
`doc/technical_details/` link the openspec capability specs
(`openspec/specs/<capability>/spec.md`) as the requirement source;
`doc/archive/` material (stage specs, TEST-SPECS) is linked only where
historical deep-dive detail has no openspec equivalent (e.g. auto-update
mechanics, OTA test matrices). Content mapping for the current README/AGENTS:

| Current section | Destination |
|---|---|
| README Quickstart + Module contract | `user_guide/quickstart.md` (merged) |
| README Module→CI wiring | `technical_details/module-ci-wiring.md` |
| README Architecture + module tables | `technical_details/architecture.md` |
| README Direct deploy (+ Auto-update) | `user_guide/deploy.md`, `user_guide/auto-update.md` |
| README Build sandboxing | `technical_details/sandboxing.md` |
| README Secrets providers | `user_guide/secrets.md` |
| README Documenting your flake | `user_guide/docs-generation.md` |
| README Reusable workflow mechanics | `technical_details/workflow-mechanics.md` |
| README Commands (repo part / consumer part) | AGENTS.md / `user_guide/quickstart.md` |
| README sha1 section | deleted (canonical: `../AGENTS.md`) |
| `doc/testing.md` | `technical_details/testing.md` (`git mv`) |
| `doc/migration/direct-deploy.md` | `user_guide/migration.md` (`git mv`) |
| `doc/specs/**` | `doc/archive/specs/**` (`git mv`, content frozen) |
| `doc/drafts/**` (incl. 0002/0003) | `doc/archive/drafts/**` (`git mv`, status notes kept) |
| (new) | `doc/archive/README.md` — freeze note pointing to `openspec/specs/` |
| user_guide/technical_details spec links | `openspec/specs/<capability>/spec.md`; archive paths only as historical supplement |
| AGENTS "What this flake exports" | README map is canonical; AGENTS links |
| AGENTS contract example / wiring / sandbox / workflow mechanics | deleted (links to the docs above) |
| AGENTS "chicken-and-egg" historical sketch | deleted (0001 + `doc/drafts/` are the record) |
| AGENTS Nix style, mkOption/test rules, commands | kept (canonical contributor content) |

`git mv` everywhere possible to preserve history.

### D2: Language policy

New/rewritten docs, the delta, and all change artifacts: English. The three
Russian requirements left in `openspec/specs/docs/spec.md` after the delta
(options reference, CI logs, migration plan) are translated in-place during
implementation, so the `docs` capability ends fully English. The archived
legacy corpus (`doc/archive/`) keeps its Russian text — it is frozen
history. The openspec specs `direct-deploy` / `deploy-user` stay Russian
until a dedicated translation sweep (explicitly deferred). Rationale: README
and code comments are already English; specs-for-humans follow; a hard
"everything now" rule would balloon the change into translating ~2800 lines
of frozen or still-evolving deploy material.

Alternative rejected: translate everything now — too large, risks drifting
from code while the deploy specs are the living design record.

### D3: Comment-rewrite policy

A rewritten comment must satisfy: the first sentence(s) state the
invariant/behaviour standalone; an optional `Background: <spec-ref>` tail may
follow. Forbidden: a comment whose whole informative content is a spec
reference or scenario code.

Example:

```nix
# before
# Stateless detection (spec §11.8 — review resolution): the provision script …

# after
# Detection is stateless: the provision script derives the current layout
# from the disk itself (no state file), so re-running it is idempotent.
# Background: doc/specs/direct-deploy/08-ab-provisioning.md §11.8.
```

Sweep targets (from audit): `modules/**` (~25 hits), `flake.nix` (spec-code
comments in checks/vmTests), `tests/*.nix` headers referencing TEST-SPECS
codes, `lib/mkDocs.nix`. Grep drivers: `doc/specs`, `spec §`, `§[0-9]`,
`(A[0-9]`, `(B[0-9]`, `(C[0-9]`, `(O[0-9]`, `(R[0-9]`, `AU-`, `K[0-9]`.
Scenario codes remain acceptable inside `tests/` assertion names (they label
test cases), but each must be preceded by a plain-language comment where the
logic is non-obvious.

### D4: Secret removal mechanics

`tests/runner.nix`: replace `runnerToken = ../secrets/runner.env;` with the
existing `dummySecret` (`/dev/null`) pattern and rewrite the header comment
(tokenFile is a path consumed at runtime, never read at eval; a real
consumer decrypts via their secret backend). No assertion inspects the
token's hostPath, so the suites are eval-identical. Then `git rm secrets/
.sops.yaml`. Manual out-of-repo step (recorded in tasks): revoke/rotate the
runner registration token on Forgejo — deleting the file does not
invalidate it.

### D5: AGENTS.md target outline

1. What this repo is (3 lines) + link to README map.
2. Repository layout (incl. `openspec/`, `doc/` layers, `artifacts/` gitignored).
3. OpenSpec in this repo: specs/changes/archive layout + the three working
   rules (mandatory docs task per change, English, self-documenting comments).
4. Contributor rules: workspace style pointer, mkOption-description rule,
   every-option-tested rule, comment policy (D3), tests wiring rule
   (checks vs vmTests).
5. Commands (repo + sandbox-probe note).
6. TODO / out of scope (secrets providers roadmap).

Everything consumer-facing is a link, per the delta requirement.

### D6: `openspec/config.yaml` additions

```yaml
context: |
  Working language: English. All documentation (README, doc/**), specs and
  change artifacts are written in English.
rules:
  proposal: [ "Write in English." ]
  specs: [ "Write in English." ]
  design: [ "Write in English." ]
  tasks:
    - Write in English.
    - Every change touching functional surfaces (modules, workflows,
      actions, options) must include a task to update README.md and the
      affected doc/user_guide/ + doc/technical_details/ documents, with
      links to the relevant doc/specs/.
```

### D7: Zero-delta verification

After each implementation phase: `nix build .#checks.x86_64-linux.runner
.#checks.x86_64-linux.deploy-target` (fast pure-eval canaries), at the end
`nix flake check --show-trace --all-systems`. The comment sweep is verified
comment-only by reviewing `git diff` per file (no token outside comments).

## Risks / Trade-offs

- [External links to README anchors break] → acceptable: the repo is young,
  the README is the declared entry point and gains a stable map; consumers
  follow the input URL, not deep anchors.
- [The committed token stays valid until manually rotated] → tasks include
  the rotation step with a visible checkbox; removing the file first still
  reduces exposure (no further ciphertext distribution).
- [Mixed-language specs after this change (deploy-user/direct-deploy stay
  Russian)] → documented as deferred; the language requirement explicitly
  scopes the exception until a dedicated sweep.
- [Comment sweep is broad (~30 sites), risk of accidental logic edits] →
  comment-only diffs reviewed per file + pure-eval canaries + final
  `nix flake check`.
- [~10 code references to `doc/specs` paths (option descriptions, comment
  Background tails, assertion messages) break when the corpus moves to
  `doc/archive/`] → the archival task sweeps them to the new paths or drops
  the pointer; a grep driver for `doc/specs|doc/drafts` is part of the task
  verification.
- [Search traffic to old doc paths (`doc/testing.md`, `doc/migration/`,
  `doc/specs/`)] → `git mv` keeps history; stale inbound references inside
  the repo are fixed in the same change (grep in tasks).

## Migration Plan

Phases (each independently revertible, docs-only):

1. Move phase: `git mv` doc/testing.md, doc/migration/, 0002/0003 → drafts.
2. Build phase: write `doc/user_guide/*`, `doc/technical_details/*` from the
   current README/AGENTS content (deduplicated, linked, English).
3. Rewrite phase: README (overview+map), AGENTS.md (D5 outline), config.yaml
   (D6), translate the 3 remaining Russian requirements of the `docs` spec.
4. Code phase: tests/runner.nix dummy swap + `git rm` secrets; comment sweep
   (D3).
5. Archive phase: `git mv` doc/specs → doc/archive/specs and doc/drafts →
   doc/archive/drafts, write the freeze README, retarget doc links to
   `openspec/specs/`, sweep the remaining code references to the moved
   paths.
6. Verify: link check (grep old paths), `nix flake check`, suite reports,
   `openspec validate --strict`.

Rollback: `git revert` of the whole change restores docs and files; no
runtime state is touched. Post-conditions for CI: none (same eval results).

## Open Questions

(none)

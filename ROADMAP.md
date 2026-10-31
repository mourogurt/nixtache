# Roadmap

This document records direction and dependency order, not release dates or
current feature guarantees. Each functional item must be split into focused
OpenSpec changes with requirements, tests and documentation before
implementation. Independent items may proceed in parallel.

## Delivery sequence

| Stage | Goal | Work items |
|---|---|---|
| **Now: stabilize** | Finish existing contract and security fixes before expanding OTA and deploy behavior. | R2 |
| **Next: operate safely** | Establish security/contribution processes, safe rollout policy, flexible credentials and operational visibility. | R3, R4, R12, R1, R1.2, R10, A1 |
| **Then: scale the ecosystem** | Add supply-chain artifacts, more CI targets, public documentation and fleet rollout mechanisms. | R5, R7, R8, A2, A3, A5 |
| **Explore / later** | Make UI and backend investments from measured requirements; verify mature state machines. | R6, R9, R11, A4 |

## R2. Complete the active OpenSpec changes

Snapshot from 2026-10-30; the authoritative task lists remain in OpenSpec.

| Change | Status | Remaining scope in short |
|---|---:|---|
| `server-ab-migration-prep` | 15/36 | Prove runner stores across A/B swaps; make slot sizes deterministic; fix poll/reboot-window behavior; implement safe post-rollback recovery; finish credential-only manifest signing, documentation and the full KVM matrix. |
| `self-update-flake` | 0/9 | Add reusable runner/validation-profile inputs and a thin scheduled self-update caller, then prove signed lock updates on the real runner. |
| `fix-docs-private-flake-access` | 4/5 | Implementation and cheap checks are complete; run the live docs workflow against an uncached private SSH input and verify the uploaded artifact. |
| `deploy-runner-contract-fixes` | 0/14 | Restrict the SSH serve gate to exact protocol forms, fix manual deploy-user membership, make sandbox probes cache-proof, coalesce slow cache fills and preserve all CI failure reports. |

**Exit gate:** all tasks are complete, strict OpenSpec validation and
`nix flake check --show-trace --all-systems` pass, required live workflows and
the full KVM matrix pass, and each change is archived with its deltas synced.
New OTA work depends especially on the A/B recovery and signing-credential
parts of `server-ab-migration-prep`.

## R1. Vault Agent provider and signing-key rotation

Introduce a secrets provider abstraction with a concrete `vault-agent`
implementation, then add a safe rollover protocol for OTA manifest signing
keys.

- Use Vault Agent for auto-auth, token/lease renewal and atomic template
  rendering. Materialise secrets with runtime-only permissions and wire
  template changes to explicit reload/restart behavior. Never place secret
  values in the Nix store, command lines, logs or generated documentation.
- Populate `services.nixtache.secrets.vars` without forcing existing modules to
  abandon their backend-agnostic secret-path options. Define least-privilege
  Vault policies per consumer and key purpose.
- Treat key rotation as a trust-protocol change, not merely a file refresh:
  distribute the new public key first, trust old and new keys during an
  overlap, switch signing, verify the fleet, and only then remove the old
  trust. Include emergency revocation and a tested rollback procedure.
- Do not assume Vault Transit output can directly replace the existing
  OpenPGP detached signatures consumed by `systemd-sysupdate`. The design must
  choose and prove either an OpenPGP-compatible signing adapter/key-delivery
  flow or a deliberate signature-format migration. Vault Agent manages local
  authentication and secret delivery; Vault/operator policy owns rotation.
- Test normal rotation, devices still running old slots, interrupted
  publication, expired/revoked keys, Vault outage and stale templates. A Vault
  outage must not invalidate already installed systems or weaken signature
  verification.

**Done when:** an old device can roll forward through two consecutive key
generations without a trust gap, emergency revocation has a documented and
tested path, and no private key appears in persistent world-readable state.

References: [Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent),
[Vault Transit](https://developer.hashicorp.com/vault/docs/secrets/transit),
[RAUC PKI and rollover patterns](https://rauc.readthedocs.io/en/stable/advanced.html#security).

## R1.2. Flake source authentication and update transports

Replace the implicit "private flakes require SSH keys" assumption with a
per-source authentication contract shared by CI, docs generation and host
auto-update.

- Support and test anonymous HTTPS, private HTTPS with short-lived tokens,
  existing SSH keys, and SSH certificates issued by a trusted CA. Evaluate
  local/offline mirrors as an explicit transport rather than an accidental
  side effect of caching.
- Keep three privileges separate: reading flake inputs, writing lock-file
  commits, and signing those commits. Provider-specific app/installation
  tokens can be adapters over the common contract, not global credentials.
- Deliver runtime credentials through protected files or systemd credentials;
  redact them from URLs, process arguments, logs, artifacts and error reports.
  TLS verification and SSH host-key/CA verification remain mandatory.
- Define token renewal, expiry, revocation and offline behavior for both
  one-shot CI jobs and long-lived host services. Cover nested private inputs,
  cached versus uncached revisions and non-fast-forward update pushes.
- Start with a transport/decision matrix and an HTTPS-token prototype, then
  prototype SSH certificates. Preserve SSH as a supported backend rather than
  forcing a migration.

**Done when:** the same public/private source matrix passes for `nix-check`,
docs, lock updates and host auto-update on at least HTTPS-token and SSH
backends, with no credential leakage in failure logs.

## R3. Security policy and vulnerability handling

Add a root `SECURITY.md` with a private reporting channel, supported releases,
scope, severity/triage targets, coordinated disclosure and advisory process.
Document how to report without exposing secrets and how maintainers handle
embargoed fixes.

Include operational ownership for signing-key compromise, malicious build
artifacts, runner/deploy-gate bypass, cache poisoning and leaked fetch/update
credentials. Link the policy from README and the contribution guide; detailed
threat-model internals should have one canonical home rather than being copied
into every guide.

**Done when:** a reporter can privately disclose an issue, maintainers have a
concrete triage/disclosure workflow, and signing/fetch credential compromise
has an actionable recovery runbook.

## R4. Contribution guide

Create `CONTRIBUTING.md` as the canonical human contributor workflow:
development setup, Nix/YAML style, option descriptions and required tests,
cheap checks versus KVM suites, OpenSpec lifecycle, documentation rules,
commit/PR expectations and review checklist.

Reduce `AGENTS.md` to agent-specific instructions plus links to shared rules.
Keep `doc/technical_details/` as the canonical internals documentation and
link to it where contributors need rationale; do not move or duplicate every
technical document into the contribution guide.

**Done when:** a new contributor can go from checkout to a reviewable change
using `CONTRIBUTING.md`, and each contributor rule has exactly one canonical
location.

## R5. SBOM generation from content-addressed derivations

Add SBOM generation for realised CA derivations, NixOS toplevels and OTA
artifacts. Reuse or package [sbomnix](https://github.com/tiiuae/sbomnix) where
possible; nixtache-specific work should focus on CA/OTA integration and missing
metadata rather than another dependency-graph crawler.

- Produce deterministic CycloneDX and SPDX artifacts with runtime/build-time
  dependency modes, derivation/output identity, hashes, source/flake revision,
  package version, license and PURL/CPE metadata when available.
- Exercise CA input/output rewriting, multi-output and fixed-output
  derivations, source-only inputs and absent package metadata. Validate output
  against the selected SBOM schemas and test that repeated generation is
  stable.
- Record uncertainty explicitly. A CA/Nix graph does not by itself recover all
  vendored, language-level or upstream dependencies, nor invent missing
  license/CPE data.
- Attach SBOMs to release and OTA manifests, hash/sign them with the same
  publication transaction, and expose them to vulnerability-scanning tooling.

**Done when:** CI publishes schema-valid SBOMs for representative CA closures
and A/B images, their dependency scope and metadata gaps are documented, and
an SBOM can be tied cryptographically to the exact released artifact.

## R6. Delta and adaptive update research

Start with a benchmark/ADR spike, not a backend migration. The current
`systemd-sysupdate` model transfers whole partitions, files or trees; direct
Nix closure transfer already avoids unchanged store paths but still transfers
changed NARs as whole units.

Measure download bytes, server storage, target CPU/IO, installation time,
interrupted-download recovery and signature-verification cost for representative
small and large upgrades. Compare:

1. **Stay on sysupdate:** prototype chunk-seeded acquisition only if it can
   preserve sysupdate's atomic installation and verification contract.
2. **RAUC streaming + adaptive `block-hash-index`:** reuse blocks from either
   slot without requiring a specific source version; also compare
   casync/desync. Account for CMS/PKI, image format, hooks, bootloader and
   operational migration costs.
3. **OSTree object replication/static deltas:** use as an architectural
   comparison, not as a drop-in NixOS backend. A switch would change deployment
   and state semantics substantially.

A backend switch is justified only by measured benefits and equivalent or
stronger rollback, power-loss, key-rollover and recovery tests. Arbitrary-source
upgrades are preferred over maintaining every pairwise delta.

**Done when:** an ADR contains reproducible benchmarks and a go/no-go decision.
Implementation is a separate change; the spike alone must not destabilise the
existing sysupdate route.

References: [systemd-sysupdate](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html),
[RAUC adaptive updates](https://rauc.readthedocs.io/en/stable/advanced.html#adaptive-updates),
[RAUC casync comparison](https://rauc.readthedocs.io/en/stable/advanced.html#casync-vs-rauc-built-in-streaming-adaptive-updates),
[OSTree atomic upgrades](https://ostreedev.github.io/ostree/atomic-upgrades/),
[OSTree static deltas](https://ostreedev.github.io/ostree/copying-deltas/).

## R7. More runners and CI providers

Separate provider-neutral build/deploy contracts from thin CI adapters.
Prioritise one additional provider end to end before promising broad support;
likely candidates are GitHub Actions, GitLab CI and Woodpecker, selected by
actual consumer demand.

- Define a support matrix for runner labels, sandbox capability, KVM,
  architecture, private-input credentials, artifact storage and reusable
  workflow/action versioning.
- Reuse core validation/deploy logic instead of copying workflow graphs.
  Provider adapters must expose the same failure diagnostics and secret
  redaction guarantees.
- Add conformance tests against real workflow syntax plus a live public and
  private consumer rehearsal. Include self-update and docs paths, not only the
  happy-path build.

**Done when:** at least one non-Forgejo provider runs check → private fetch →
artifact/docs → deploy with the same consumer contract, and unsupported runner
capabilities fail early with actionable messages.

## R8. Project website and published documentation

Publish a static site from the existing user guide, canonical specs, generated
option reference and contribution/security documents. Keep README as the map
and avoid creating website-only copies of documentation facts.

Provide navigation, search, stable URLs, link checking, accessible markup and
CI preview builds. Publish `main` first; add versioned documentation after the
release/compatibility policy in A5. The publishing workflow must not require
secrets for untrusted documentation content or expose private consumer URLs.

**Done when:** a documentation change produces a reviewable site artifact, the
published site passes link/accessibility checks, and option documentation is
generated from modules rather than maintained by hand.

## R9. Build and package-store status Web UI

Build a read-only MVP only after R10 and the required CI event/inventory API
exist. Show build/deploy results and durations, target generation or OTA slot,
pending updates and rollbacks, cache capacity/availability, and links to signed
release/SBOM artifacts.

- Use authenticated APIs with pagination and a documented schema; do not scrape
  private logs or expose raw credentials and sensitive flake URLs.
- Add RBAC and audit-friendly redaction from the first version. Keep trigger,
  retry, rollback and garbage-collection actions out of the MVP; write actions
  require a separate authorisation and CSRF/replay-threat design.
- Prefer consuming metrics/events already emitted by CI and target modules over
  creating a second, inconsistent source of operational truth.

**Done when:** an operator can answer "what is deployed, what failed, and what
is consuming cache storage" without reading raw CI logs, while unauthorised
users cannot enumerate private targets or artifacts.

## R10. Metrics, Grafana dashboards and alerts

Add an optional NixOS observability module with Prometheus exporters, curated
Grafana dashboards and alert rules as code.

Cover build/deploy outcome and duration, active runner jobs, policy denials,
current/pending OTA version, boot assessment and rollback count, cache bytes,
hit/miss and upstream latency, disk pressure, and signing-credential expiry.
Export key identifiers/expiry only, never secret values or credentialed URLs.
Bound label cardinality and document target-label privacy.

Alert on repeated rollback, stale updates, persistent policy starvation, low
space, cache unavailability and approaching signing-key expiry. Test scrape
configuration, dashboard JSON and representative alert expressions.

**Done when:** a consumer can import one module and obtain working scrape
configuration, dashboards and actionable alerts without manually discovering
unit names or metric labels.

## R11. Formal verification of update processes

Model focused state machines after R2 and R12 stabilise: direct activation and
confirmation/rollback; A/B acquire/stage/cutover/boot-assessment/recovery; and
deployment admission with windows, locks and retries.

Choose TLA+/PlusCal or an equivalent model checker in the design. Check safety
properties such as never deleting the running slot, never installing an
unverified manifest, always retaining a recovery generation, never rebooting
when a mandatory predicate denies admission, and never allowing two activation
owners. Define liveness assumptions explicitly rather than claiming fairness
that systemd/networks do not provide.

Connect model traces to executable VM/fault-injection scenarios so model drift
is visible. This is verification of nixtache protocols, not a claim to verify
all of NixOS, systemd or consumer configuration.

**Done when:** CI checks the models, at least one non-trivial fault scenario is
covered both by model trace and VM test, and each proved property names its
assumptions and implementation counterpart.

## R12. Deployment admission and rollout policy

Unify CI deploy and timer-driven update decisions in a composable, target-side
policy. Separate acquisition/staging from activation/reboot so a closed
maintenance window does not necessarily prevent safe downloads.

Built-in predicates should include time windows with explicit timezone/DST
semantics, runner idleness, required systemd unit health/inactivity, load and
disk thresholds. Add bounded Prometheus-query and custom-executable predicates
for site-specific conditions. Provide a conservative preset: healthy target,
runner drained, and activation inside a maintenance window.

- Mandatory predicate errors, stale metrics and hook timeouts fail closed;
  optional predicates are explicit. Record decision reasons and support a
  dry-run/explain mode.
- Custom hooks use fixed argv, an unprivileged sandbox, output limits and a
  timeout. Secrets are supplied through credentials, never command arguments.
- An idle check alone is racy: pair it with a target-side admission lock and a
  runner drain/lease so no new job can start between the check and activation.
  The same lock must arbitrate CI and timer-driven updates.
- Make emergency override explicit, authenticated and auditable; it must not
  disable signature verification or post-activation health checks.
- Test cross-midnight/DST boundaries, active-job arrival races, stale Grafana or
  Prometheus data, hook timeout, lock loss and policy behavior during rollback.

**Done when:** conflicting CI/timer deploys cannot activate concurrently, a new
runner job cannot slip through the idle-check race, and every denial or
override has an actionable journal/audit record.

## Additional candidates

### A1. Target-side deployment confirmation

Borrow the useful part of deploy-rs "magic rollback": after direct activation,
the target rolls back unless the deployer confirms connectivity and required
health within a bounded interval. This covers the case where activation
succeeds locally but networking or SSH is lost before CI can observe it.
Integrate it with R12 locking and existing `criticalUnits` checks rather than
creating a second rollback mechanism.

Reference: [deploy-rs](https://github.com/serokell/deploy-rs).

### A2. Fleet channels, canaries and rollout waves

Add target tags/channels and bounded rollout waves: canary → early adopters →
stable fleet, with pause criteria based on R10 health and rollback signals.
Colmena's tag selection is a useful NixOS deployment analogue. Keep fleet
orchestration separate from the target-side safety policy so offline targets
cannot block safe local recovery indefinitely.

Reference: [Colmena](https://github.com/nix-community/colmena).

### A3. Signed provenance and reproducibility checks

Publish build provenance alongside signatures and SBOMs: source lock revision,
builder/workflow identity, build inputs and artifact hashes. Add an optional
rebuild-and-compare lane for reproducible artifacts and report differences
without silently treating non-reproducibility as proof of compromise. Evaluate
SLSA-compatible provenance generation already present in the sbomnix ecosystem
before implementing a new format.

### A4. Offline recovery and update media

Support an audited path for exporting a signed update plus its manifest, public
trust and SBOM to removable/local media, then installing without internet.
Document recovery from full cache/storage, unavailable Vault and a failed
slot. Power-loss and wrong-media tests are mandatory; offline mode must not
become a signature-verification bypass.

### A5. Release, compatibility and state-migration policy

Define supported nixpkgs/Nix/systemd combinations, release tagging and notes,
option deprecation/migration rules, and rollback compatibility for persistent
state. A/B rollback must not silently depend on newer data schemas, filesystem
feature flags or one-way migrations. Versioned documentation in R8 and fleet
channels in A2 consume this policy.

## Execution rules

- Do not implement R1, R6 or R9 as monolithic changes: split provider
  integration from trust rollover, research from backend migration, and status
  API from Web UI.
- Every new option and behavior receives pure-eval coverage; safety-critical
  update paths also receive failure-injection VM coverage.
- Reuse maintained protocols and existing tools where their trust and state
  models fit. Do not switch OTA backends solely for a bandwidth feature.
- Update this roadmap at milestone boundaries; OpenSpec remains the source of
  truth for concrete requirements and task-level progress.

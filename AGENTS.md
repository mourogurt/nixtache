# AGENTS.md - nixtache

Reusable, **vendor-agnostic** NixOS CI/CD flake. Provides the Forgejo Actions
runner as a NixOS module, plus the reusable Forgejo workflows and composite
actions that build/validate consumer flakes. Any project can consume it
**without forking**.

> Workspace-level overview and shared code style live in the parent
> `../AGENTS.md`. This file is nixtache-specific.

## What this flake exports

```nix
inputs.nixtache.url = "git+ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git";
# ...
nixtache.nixosModules.runner        # (or .default alias)
nixtache.nixosModules.deploy-target # direct-deploy target side
nixtache.nixosModules.ab-image      # A/B appliance image config
nixtache.nixosModules.overlay-nix   # writable store overlay for appliances
nixtache.nixosModules.auto-update   # unified auto-update channel
nixtache.nixosModules.secrets       # secrets provider abstraction (vars + providers)
nixtache.lib.mkDocs                 # consumer docs helper (configurations + devShells)
```

- **`nixosModules.runner`** — `services.nixtache.runner`: a NixOS container
  running `gitea-actions-runner` (forgejo-runner) with a configurable nix
  store location (`store.path`: `"/"` reuses the container's system nix-daemon;
  any other base like `/srv` relocates the store to `<path>/nix` via a custom
  `nix-daemon` + storage oneshot; `store.mode` picks `clone` vs `overlay`
  population), a `nix-serve-ng` binary cache, an nginx vhost, and
  **multi-instance** support (`instances.<name>`). Exports `gitUser` + `bot`
  identity to every CI job via act_runner `runner.envs` (see "Module → CI
  wiring" below). All project-specific values are options; **secrets are
  `types.path`, supplied by the consumer**. Source split by responsibility
  under `modules/runner/` (default/types/store/cache/ssh/sandbox/known-hosts/
  instances/deploy/ab) — all contributions merge into one container via
  `mkMerge`.
- **`nixosModules.deploy-target`** — `services.nixtache.deploy-target`:
  imported by EVERY deploy target. Provisions the root
  `nixtache-apply.service` (set profile → switch → probe `criticalUnits` →
  ROLLBACK re-activating the previous closure), polkit start-only rules, the
  `nixtache-deploy` group + `/var/lib/nixtache` pointer dir, the deploy user
  (system user, uid < 1000, `nixtache-ssh-gate` `restrict,command=` key,
  added to `nix.settings.trusted-users` unconditionally — protocol
  requirement of `nix copy --to ssh://` serve-write), Tier-0
  `nixtache-health-check.service` on `boot-complete.target`, and the
  `ab.*` runtime options (gating, partition provisioning).
- **`nixosModules.ab-image`** — `services.nixtache.ab-image`: build-time A/B
  image config (repart slots + UKI + sysupdate transfers +
  `system.image.{id,version}` + boot counting + GPG verify). Imports the
  image-based-appliance profile (`nix.enable = false`) — A/B targets only.
  Remote targets update via `systemd-sysupdate-reboot.service`; the runner
  host self-updates through the idle-gated `nixtache-ab-apply`.
- **`nixosModules.overlay-nix`** — `services.nixtache.overlay-nix`: layers a
  writable OverlayFS on `/nix/store` (lower = RO image store, upper =
  writable) via `local-overlay-store`, so image-based targets can install
  packages at runtime.
- **`nixosModules.auto-update`** — `services.nixtache.auto-update`: unified
  auto-update replacing `system.autoUpgrade` (asserted): method
  `auto|flake|ab-image`, shared timer, flake path builds toplevel → pointer →
  `nixtache-apply` (never `nixos-rebuild`), ab path triggers sysupdate,
  `rebootPolicy never|if-needed|window`. See
  `doc/specs/direct-deploy/09-auto-update.md`.
- **`nixosModules.secrets`** — `services.nixtache.secrets`: provider
  abstraction. `vars` (name → path, internal) is the uniform end result;
  `providers` is an extensible attrset (ssh/forgejo/vault/systemd roadmap,
  any combination). Today the runner consumes direct path options; `vars` is
  the target providers write into. See modules/secrets.nix.
- **Direct deploy (summary).** Runner-side `deploy.targets.<name>` map
  (serialized to job env `NIXTACHE_DEPLOY_TARGETS`, keys as `deploy_ssh_*`
  LoadCredential) → reusable `deploy.yml` workflow → `deploy-target` action →
  target-side module. Spec: `doc/specs/0001-direct-deploy.md` +
  `doc/specs/direct-deploy/*`; consumer migration:
  `doc/migration/direct-deploy.md`.
- **`lib.mkDocs`** — consumer docs helper. Generates `configurationDocs-<machine>`
  (via `nixosOptionsDoc`, scoped by `optionPrefixes`) + `devShellDocs` + a
  combined `docs` artifact. Consumers expose it under `packages.<system>` and
  build via the reusable `docs.yml` workflow. See README "Documenting your flake".
- **`packages.<system>.optionsMarkdown` / `.optionsJSON` / `.optionsHTML`**
  (`.default` = `optionsMarkdown`) — this flake's OWN option reference,
  generated from ALL nixtache modules via `nixosOptionsDoc` (scoped to
  `services.nixtache.*`). Built into the `nixtache-options` artifact by
  self-CI.
- **`checks.<system>`** — pure-eval test suites: `runner`, `deploy-target`,
  `ab-image`, `mkDocs`, `ab-existing`, `ab-contract`, `auto-update` (no
  `.default` alias). Built by every `nix flake check`; each prints an ok/FAIL
  report. Build one with `nix build .#checks.x86_64-linux.<suite>`.
- **`vmTests.x86_64-linux`** — KVM-only suites: `ab-deploy`, `ab-ota-e2e`,
  `ab-ota-anywhere-vm`, `ab-vm`, `ab-provision-vm`, `overlay-nix-vm`,
  `overlay-nix-install-vm`, `overlay-nix-ab-swap-vm`, `runner-store-mode-vm`,
  `ab-runner-compat-vm`, `ab-compression-vm`, `ab-staging-vm`,
  `ab-deploy-self-vm`, `ab-ota-verify-vm`, `auto-update-vm`. NOT a checked
  output — `nix flake check` skips it; run explicitly on a KVM host with
  `nix build .#vmTests.x86_64-linux.<suite>`.
- **`nixosConfigurations.abtest-remote`** — dogfood fixture for
  `tests/ab-deploy.nix` (the action's `nix build .#nixosConfigurations.…`
  resolves inside nixtache itself). NOT for real deployment.
- **`.forgejo/workflows/{nix-check,deploy,docs,update-flake}.yml`** —
  reusable workflows (`on: workflow_call`) for consumer repositories.
- **`.forgejo/workflows/ci.yml`** — nixtache's **own** CI: on push/PR to
  `main`, runs `nix flake check` (which builds `checks.*`), prints every
  suite's test report, and generates the `nixtache-options` docs artifact.
  Not reusable — nixtache exposes no consumer-facing `nixosConfigurations`
  (only the `abtest-remote` dogfood fixture) and no `devShells`, so it
  deliberately does not call `rebuild-configurations`/`rebuild-devshells`.
- **`.forgejo/actions/{ssh-setup,flake-validation,rebuild-configurations,rebuild-devshells,generate-docs,deploy-target,sandbox-probe}`**
  — reusable composite actions.
- **`README.md`** — user-facing documentation (quickstart, architecture,
  wiring, direct deploy, sandboxing, secrets providers, "Documenting your
  flake", sha1).
- **`doc/specs/`** — `0001-direct-deploy.md` + `direct-deploy/` stages 01–10 +
  TEST-SPECS* (the deploy feature's design + test contracts).
- **`doc/migration/direct-deploy.md`** — consumer migration guide (adopting the
  deploy feature, moving to auto-update, BREAKING changes).
- **`doc/drafts/migration-plan.md`** — the original migration plan +
  architectural decisions (Q1–Q5) (superseded historical draft).

## CRITICAL: this repo MUST stay `sha1`

Nix 2.34.8 cannot fetch `sha256` git repos — it parses the rev as sha1
(40 chars) and rejects sha256 revs (64 chars). Both `git+ssh` and tarball
fetchers break. See [NixOS/nix#9980](https://github.com/NixOS/nix/issues/9980),
PR [#14526](https://github.com/NixOS/nix/pull/14526) (draft, not merged;
expected after libgit2 2.0 ships sha256 as non-experimental).

- Local repo: `git config extensions.objectFormat` must be **unset** (= sha1).
- Remote `nixops/nixtache` on Forgejo: created sha1. Object format is
  immutable on a bare repo — changing it requires **delete + recreate**.
- If you ever re-`git init --object-format=sha256`, every consumer's
  `nix flake lock` breaks.

## Module contract (consumer-facing options)

The module takes **paths** for secrets and **values** for everything
project-specific. It declares **no** `sops.secrets` and stores **no** files.

```nix
services.nixtache.runner = {
  enable        = true;
  forgejoUrl    = "http://localhost:3000";          # Forgejo/Gitea URL (shared by all instances)
  containerName = "runner";                         # NixOS container name
  package       = pkgs.forgejo-runner;              # forgejo-runner (set pkgs.gitea-actions-runner for Gitea)
  flakeSshCreds = {                                 # SSH creds to fetch PRIVATE flake inputs (e.g. nixos-private)
    user = "forgejo"; sshPrivateKey = config.sops.secrets.forgejo-private-key.path;
    sshPublicKey = config.sops.secrets.forgejo-public-key.path;
  };
  updateSshCreds = {                                # SSH creds for update-flake (push + sign). null ⇒ update-flake disabled
    user = "forgejo"; sshPrivateKey = config.sops.secrets.forgejo-private-key.path;
    sshPublicKey = config.sops.secrets.forgejo-public-key.path;
  };
  bot           = { name = "fbot"; email = "fbot@localhost"; };  # commit author → NIXTACHE_BOT_NAME/EMAIL
  instances     = {                                 # one gitea-runner-<name> per attr; each needs its own tokenFile
    default = { name = "nixos-container-runner"; tokenFile = config.sops.secrets.runner-token-default.path; };
    test    = { labels = [ "nixos:test" ]; tokenFile = config.sops.secrets.runner-token-test.path; };
  };
  cache = { enable = true; domain = "bincache.example.com"; port = 5000; };
  store.path = "/srv";                           # base dir; store lives at <path>/nix. "/" = system nix-daemon
  store.hostBackup = "/srv/bincache";            # host dir mounted at store.path
  nixSettings   = { substituters = [...]; trusted-public-keys = [...]; max-jobs = 1; cores = 8; };
  enableSandbox = false;                          # default — nix sandbox is unreliable in nspawn (CAP_SYS_ADMIN alone insufficient); container is the isolation boundary. true = opt-in if verified.
  additionalCapabilities = [ "CAP_NET_ADMIN" ];   # extra caps merged on top of the sandbox one (optional)
  gitHost       = { name = "forgejo_ed25519"; hostNames = [ "git.example.com" "10.0.0.1" "localhost" ]; publicKey = "ssh-ed25519 AAAA..."; };
  extraKnownHosts = [ { name = "github_ed25519"; hostNames = [ "github.com" ]; publicKey = "ssh-ed25519 AAAA..."; } ];
  deploy.targets = {                                # direct-deploy map; attr name MUST equal nixosConfigurations.<name>
    desktop = { host = "desktop.example.com"; sshPrivateKey = config.sops.secrets.deploy-desktop-key.path; };
  };
  secrets.cachePrivateKey = config.sops.secrets.cache-private-key.path;
  # Secret paths can come from sops, agenix, vault-agent, systemd
  # LoadCredential, etc. The module is backend-agnostic by design.
};
```

The registration token is **per-instance** (`instances.<name>.tokenFile`), not
global. Resource limits (`memoryMax`, `memoryHigh`, `timeoutStartSec`), runner
package, host packages, timeouts, log level are all options with sensible
defaults.

## Module → CI wiring (`flakeSshCreds`, `updateSshCreds`, `bot`)

The runner host is configured by the consumer; CI workflows/actions run on it
as jobs. Deployment-specific values (SSH user, bot identity) are NOT hardcoded
in YAML — the module exports them into every job via act_runner's
**`runner.envs`** (a mode-agnostic config key — applies to `host` jobs too,
not just docker), and the bot SSH keys via systemd **`LoadCredential`**:

| module option | job env / credential | used by |
|---|---|---|
| `flakeSshCreds.user` | `NIXTACHE_FLAKE_GIT_USER` + `flake_ssh_*` LoadCredential | `ssh-setup` (creds: flake) → fetch private flake inputs (`nix flake check`) |
| `updateSshCreds.user` | `NIXTACHE_UPDATE_GIT_USER` + `update_ssh_*` LoadCredential | `ssh-setup` (creds: update) + `update-flake.yml` push URL + commit signing |
| `bot.name` / `bot.email` | `NIXTACHE_BOT_NAME` / `NIXTACHE_BOT_EMAIL` | `update-flake.yml` commit author |
| `gitHost.hostNames[0]` | `NIXTACHE_GIT_SSH_HOST` | `update-flake.yml` SSH push host (canonical SSH endpoint; `GITHUB_SERVER_URL` is HTTP-only — its port is the HTTP port, not SSH) |

`*.user` is the git SSH **transport** user (server's `RUN_USER`, e.g.
`forgejo`/`git`) — not the bot account. The two bundles are **independent**:
`flakeSshCreds` gates private-input fetch, `updateSshCreds` gates update-flake
push. Typically the consumer points both at the same key files. If
`updateSshCreds = null`, `NIXTACHE_UPDATE_GIT_USER` is empty and
`update-flake.yml` **self-disables** (a guard step no-ops the job with a
warning). The bot's commit identity is separate (`bot.*`).

## Build sandboxing (`enableSandbox`, `SANDBOX_OK`)

The runner is a NixOS `systemd-nspawn` container. NixOS sets
`nix.settings.sandbox = true` by default, **but nspawn drops `CAP_SYS_ADMIN`
from the container's bounding set** and locks /proc submounts, so
`nix-daemon` inside cannot create the user/mount namespaces + bind-mounts
the sandbox needs — every `nix build` / `nix flake check` fails with
`this system does not support the kernel namespaces that are required for
sandboxing`. The default is therefore **`false`** (working CI; the container
itself is the isolation boundary):

| option | default | effect |
|---|---|---|
| `enableSandbox` | `false` | unprivileged container, forces `nix.settings.sandbox = false` |
| `enableSandbox` | `true` (opt-in) | grants `CAP_SYS_ADMIN` to the container, forces `nix.settings.sandbox = true`, applies the daemon `/proc` remount fix (PrivateMounts + fresh procfs on both daemons). Use only on nspawn setups verified to sandbox |
| `additionalCapabilities` | `[]` | extra caps merged on top of the sandbox one (optional) |

**CI side — runtime probe.** The `sandbox-probe` composite action builds a
fresh probe derivation at job start and exports `SANDBOX_OK=1` (sandbox
usable) / `SANDBOX_OK=0` (fall back) to the job env. All build actions
(`flake-validation`, `rebuild-configurations`, `rebuild-devshells`,
`generate-docs`, `deploy-target`) and nixtache's own `ci.yml` append
`--no-sandbox` when `SANDBOX_OK ≠ 1`, so a runner whose sandbox is broken
(or not yet rebuilt with the fix) self-heals instead of failing.

The module still exports a static `HAS_SANDBOX_CAP` env (mirrors
`enableSandbox` 1:1), but **nothing consumes it** — it is legacy; do not wire
new code to it. `SANDBOX_OK` from `sandbox-probe` is the operative flag.

> Deployment note (chicken-and-egg, see "Bootstrap & deploy" below): the cap
> is granted only after the server is rebuilt with the updated module, so a
> first-time rollout needs one manual `nixos-rebuild switch` (or an
> `ab-image` deploy) on the server. The runtime probe keeps CI green on both
> sides of that switch.

## Consumer pattern

1. Add the flake input (`git+ssh`, see above) and import
   `nixtache.nixosModules.runner` into the host's modules.
2. Write a thin **instance** that owns the secrets (e.g. `sops.secrets.*`)
   and feeds the module options + secret paths.
3. Replace the consumer's `.forgejo/workflows/*.yml` with thin wrappers:
   `jobs.X.uses: nixops/nixtache/.forgejo/workflows/<wf>.yml@main`.
   Delete the consumer's `.forgejo/actions/` (use nixtache's).

Reference consumer: `codemaster/nixos-configuration`
(`server/services/forgejo-runner.nix` is the instance).

## Commands

```bash
# Validate this flake (note: repo must be sha1, see above)
nix flake check --show-trace --all-systems

# Evaluate the module standalone (no host needed) — sanity-check options
nix-instantiate --parse modules/runner/default.nix > /dev/null && echo OK

# Build this flake's own generated option reference
nix build .#optionsMarkdown && cat ./result

# SSH commit signing for this repo (if pushing bot commits):
#   bot key path comes from the ssh-setup action output `key-path`.
```

## Reusable workflow mechanics (Forgejo)

- A reusable workflow (`on: workflow_call`) invoked from a caller repo runs
  in the **caller's** checkout context (`actions/checkout@v4` checks out the
  caller, so `nix flake show` sees the caller's configs).
- To resolve **this repo's** composite actions, the reusable workflow checks
  out `nixops/nixtache` into `.nixtache/` and uses
  `./.nixtache/.forgejo/actions/<name>`. (Robust against Forgejo's
  cross-repo action path resolution.)
- In the Forgejo UI a reusable call renders as two jobs: `<name>` (0s caller)
  and `<name>-1` (the work). Expected.

## Bootstrap & deploy: the chicken-and-egg (future task)

> **Realized & superseded by `doc/specs/0001-direct-deploy.md`** (ouroboros:
> two host-level deployers on the nixtache infra machine; multi-tier auto-
> rollback; least-privilege deploy user). This section is the original sketch —
> kept for context. Below, "the server" = "the machine running the nixtache
> runner" (the infra machine); `desktop`/`laptop` = target machines. These are
> **examples** from the reference workspace, not fixed roles — nixtache is
> vendor-agnostic.

**Problem.** The Forgejo CI runner is itself declared in the server's NixOS
config (`services.nixtache.runner` in nixos-configuration). When that config
changes in a way that affects how CI runs — the runner module contract
(`flakeSshCreds`/`updateSshCreds`, LoadCredential names), the `ssh-setup`
action, or the reusable workflows — the **deployed** runner keeps running the
OLD code until `nixos-rebuild switch`. Meanwhile the NEW workflow (checked out
from `nixtache@main` / the consumer's `main`) already expects the new runner.
Result: CI fails — e.g. `ssh-setup` (`creds: flake`) skips because
`flake_ssh_*` is absent on the old runner, a stale `core.sshCommand` lingers in
`~/.gitconfig`, and `nix flake check` can't git+ssh-fetch private inputs. The
runner can't deploy itself, because deploying restarts the very container the
job runs in — a chicken-and-egg.

**Goal.** A deploy path that activates the server config from an executor that
is NOT the nixtache runner container, so "update the runner" is decoupled from
"run CI on the runner". After a deploy, the regular runner restarts with the
new config and the main CI proceeds normally.

**Design — a stable "deploy" executor + a deploy workflow.**

1. **Bootstrap runner** — a second runner that is NOT inside the nixtache
   container and whose config is intentionally minimal and rarely changed:
   - either a host-level runner on the server (a separate
     `services.gitea-actions-runner.instances.deploy` running directly on the
     host, label `deploy:host`), or
   - a runner on a different machine with SSH access to the server.
   It lives outside the container, so rebuilding the server (and restarting
   the `default`/`test` containers) does not interrupt it. It only needs to
   build flakes and run `nixos-rebuild`/`deploy-rs` over SSH.

2. **`deploy.yml`** (reusable workflow in nixtache, thin wrapper in the
   consumer) — `runs-on: deploy`, on push to `main` (or `workflow_dispatch`):
   checkout consumer flake → build `.#nixosConfigurations.server` → activate
   over SSH with a dedicated **deploy key** (a separate credential with host
   login rights — NOT the fbot git-bot key) via `nixos-rebuild switch --flake
   .#server --target-host …` or `deploy-rs`/`colmena`. On success the
   `default`/`test` runner containers restart with the new module config.

3. **Sequencing** — the main CI (`nix-check.yml`) runs only after the deploy
   succeeds, on the now-updated regular runner: either two jobs in one
   pipeline (`deploy` on `runs-on: deploy` → `check` on `runs-on: nixos` with
   `needs: deploy`), or `nix-check` triggered via `workflow_run` on
   `deploy.yml` completion.

4. **Bootstrap-of-the-bootstrap** — the deploy runner must be brought up
   manually once (initial `nixos-rebuild switch` that starts the `deploy`
   instance). After that it's self-sustaining as long as its minimal config
   doesn't break; if it ever does, another manual bootstrap. Keep its config
   tiny and stable on purpose.

5. **Rollback resilience** — because the deploy runner is separate, a bad
   deploy that breaks `default`/`test` does NOT brick CI: the deploy runner can
   re-run and roll the server back. This is the main robustness win over "the
   runner rebuilds itself".

**Lighter alternative (status quo).** No bootstrap runner; document that
changes touching the runner module contract or the CI workflows require a
one-time **manual** `nixos-rebuild switch` on the server, and CI-driven
deploys handle only non-runner-breaking changes. Cheaper, but every contract
change needs a human deploy and there is no auto-rollback.

**Open sub-decisions (all resolved in `doc/specs/0001-direct-deploy.md`):**
- deploy tool: **decided — none.** Activation is the root systemd unit
  `nixtache-apply.service` + polkit (V2). No deploy-rs / colmena / sudo / doas /
  run0 — the escalation-tool zoo is gone entirely.
- deploy-key scope: dedicated `nixos-deploy` user, least-privilege (SSH +
  `nixtache-deploy` group for the pointer dir + polkit on `start` of the one
  apply unit — no sudo).
- where the deploy runner lives: the existing runner instances (no separate
  bootstrap runner); `method = "ab-image"` (systemd-sysupdate) solves the
  server self-update chicken-and-egg instead.
- whether `deploy.yml` gates `nix-check`: yes — combined pipeline, `deploy`
  job `needs: build` (variant b).

See also `doc/drafts/migration-plan.md` "Контракт деплоя" for the original deploy
contract stubs.

## Nix style

Follows the workspace conventions (`../AGENTS.md`): 2-space indent, kebab-case
files, camelCase vars, `{ config, lib, pkgs, ... }:` signature, `mkIf`/
`mkMerge`/`mkOption` with `defaultText`, `lib.literalMD`/`lib.literalExpression`
for non-trivial defaults.

**No changelog comments in code** (Nix, YAML workflows/actions, bash alike) —
applies workspace-wide. Explanations of *why a line was added / removed /
changed* (e.g. `# X removed upstream …`, `# renamed from Y`) go in the
**commit message**, never inline; inline comments document non-obvious *logic*
only, and a deletion stays a deletion (no tombstone comments). See workspace
`AGENTS.md` → "Comments & commit messages".

### Every `mkOption` MUST have a `description` (enforced in CI)

**Rule:** never commit an `mkOption` / `mkEnableOption` without a `description`
(also covers submodule `options` like the ones in `modules/runner/types.nix`).
This is enforced: `nixosOptionsDoc` for this flake's own
`packages.optionsMarkdown`/`optionsJSON`/`optionsHTML` runs with
`warningsAreErrors = true` (the default), so an undocumented option BREAKS the
docs build in `ci.yml`. `mkEnableOption` auto-generates a description, so it's
fine — but plain `mkOption { type = ...; }` with no `description` will fail CI.

Consumers are not bound to this strictness: `nixtache.lib.mkDocs` accepts
`docStrictMode ? false` — a consumer may opt into the same enforcement by
passing `docStrictMode = true` to its `packages.<system>.<mkDocs call>`.

### Every option MUST be covered by a test

**Rule:** every consumer-facing `mkOption` (and each meaningful behaviour of
its `config`) gets at least one assertion in `tests/`. Options without tests
are considered unfinished. The existing pattern to follow is
`tests/runner.nix` (pure-evaluation scenarios: each builds a `nixosSystem`
with specific option values and asserts on `config.*` attributes — services
present, envs wired, caps granted, mounts/BindPaths, assertions firing).
`tests/mkDocs.nix` is the analogous suite for `lib/mkDocs.nix`.

Add new tests whenever you add an option or change behaviour; run them locally
with `nix build .#checks.x86_64-linux.<suite>` and read the printed report.
New test files MUST be wired into `flake.nix`: pure-eval suites into
`checks.<system>` (built by every `nix flake check`, so they must stay
build-cheap), KVM/runNixOSTest suites into `vmTests.x86_64-linux` (NOT a
checked output — `nix flake check` skips it; run explicitly on a KVM host
with `nix build .#vmTests.x86_64-linux.<suite>`).

## TODO / out of scope here

- **Secret provider implementations.** The provider abstraction
  (`services.nixtache.secrets.{vars,providers}`) is in place — see
  `modules/secrets.nix`. The runner today consumes direct path options (the
  stable contract); concrete provider modules (`ssh`, `forgejo`, `vault` as
  primary, `systemd`) land incrementally, each just appending to `vars`. Vault
  is the intended primary, ssh the supplementary one.

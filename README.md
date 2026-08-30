# nixtache

Reusable, **vendor-agnostic** NixOS CI/CD flake. Provides the Forgejo Actions
runner as a NixOS module, a binary cache, a secrets-provider abstraction, a
direct-deploy pipeline (CI → your machines), and the reusable Forgejo
workflows + composite actions that build, validate and document consumer
flakes. Any project can consume it **without forking**.

- **What you import:** six NixOS modules — `nixtache.nixosModules.runner`
  (the Actions runner in a NixOS container), `.deploy-target` (receive direct
  deploys), `.ab-image` (A/B appliance image config), `.overlay-nix` (writable
  store overlay for appliances), `.auto-update` (unified auto-update channel),
  `.secrets` (secrets-provider abstraction).
- **What gets generated:** option references for this flake AND helpers
  (`nixtache.lib.mkDocs`) so consumers document their own configurations and
  devShells.
- **What nixtache never stores:** secrets and project-specific values (hosts,
  domains, keys). All of that is supplied by the consumer via module options.

> See [`AGENTS.md`](AGENTS.md) for repo-specific contributor notes,
> [`doc/specs/0001-direct-deploy.md`](doc/specs/0001-direct-deploy.md) for the
> direct-deploy design, [`doc/migration/direct-deploy.md`](doc/migration/direct-deploy.md)
> for the consumer migration guide, and
> [`doc/drafts/migration-plan.md`](doc/drafts/migration-plan.md) for the
> historical draft (Q1–Q5) that shaped this repo. The option reference
> is generated into the CI artifact `nixtache-options` (build locally with
> `nix build .#optionsMarkdown` / `.#optionsJSON` / `.#optionsHTML`).

---

## Contents

- [Quickstart](#quickstart)
- [Architecture](#architecture)
- [Module contract](#module-contract)
- [Module → CI wiring](#module--ci-wiring)
- [Direct deploy (CI → machines)](#direct-deploy-ci--machines)
  - [Auto-update](#auto-update)
- [Build sandboxing](#build-sandboxing)
- [Secrets providers](#secrets-providers)
- [Documenting your flake](#documenting-your-flake)
- [CRITICAL: this repo must stay `sha1`](#critical-this-repo-must-stay-sha1)
- [Commands](#commands)

---

## Quickstart

1. **Add the flake input** (`git+ssh`, same pattern as a private secrets
   flake):

   ```nix
   inputs.nixtache.url = "git+ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git";
   ```

2. **Import the runner module** into your host's modules and feed it options
   + secret paths. The module declares **no** `sops.secrets` — you own the
   secret declarations and feed the resulting paths in:

   ```nix
   { config, nixtache, ... }: {
     imports = [ nixtache.nixosModules.runner ];

     services.nixtache.runner = {
       enable        = true;
       forgejoUrl    = "http://localhost:3000";
       containerName = "runner";
       flakeSshCreds = {                                 # SSH creds to fetch PRIVATE flake inputs
         user = "forgejo";
         sshPrivateKey = config.sops.secrets.forgejo-private-key.path;
         sshPublicKey  = config.sops.secrets.forgejo-public-key.path;
       };
       updateSshCreds = {                                # SSH creds for update-flake (push + sign); null ⇒ disabled
         user = "forgejo";
         sshPrivateKey = config.sops.secrets.forgejo-private-key.path;
         sshPublicKey  = config.sops.secrets.forgejo-public-key.path;
       };
       bot = { name = "fbot"; email = "fbot@localhost"; };
       instances.default.tokenFile = config.sops.secrets.runner-token-default.path;
       cache = { enable = true; domain = "bincache.example.com"; port = 5000; };
       store.path      = "/srv";       # base dir; store lives at <path>/nix. "/" = system nix-daemon
       store.hostBackup = "/srv/bincache";
       gitHost = { name = "forgejo_ed25519"; hostNames = [ "git.example.com" "localhost" ]; publicKey = "ssh-ed25519 AAAA..."; };
       secrets.cachePrivateKey = config.sops.secrets.cache-private-key.path;
     };
   }
   ```

3. **Replace your `.forgejo/workflows/*.yml`** with thin wrappers that call
   nixtache's reusable workflows, and delete your `.forgejo/actions/` (use
   nixtache's):

   ```yaml
   # .forgejo/workflows/nix-check.yml
   jobs:
     check-flake:
       uses: nixops/nixtache/.forgejo/workflows/nix-check.yml@main
       secrets: inherit
   ```

4. **(Optional) Generate your flake's docs** — see
   [Documenting your flake](#documenting-your-flake).

Reference consumer: `codemaster/nixos-configuration`
(`server/services/forgejo-runner.nix` is the instance).

> **Role model (vendor-agnostic).** nixtache не фиксирует роли машин.
> **Infra-машина** — та, что крутит Forgejo Actions runner
> (`services.nixtache.runner`); **таргет-машины** — те, куда деплоит фича
> deploy (`doc/specs/0001-direct-deploy.md`). В этом reference workspace
> infra = `server`, таргеты = `desktop`/`laptop`/`server`; `server`/`desktop`/
> `laptop` ниже — **примеры**, не роли.

---

## Architecture

```
                        ┌─────────────────┐
    nixos-private ─────▶│                 │  inputs.secrets   (git+ssh)
    (nixosModules.*)     │                 │
                         │  nixos-         │
    nixtache ───────────▶│  configuration  │  inputs.nixtache  (git+ssh)
    (nixosModules:       │   laptop/       │   ├─ nixosModules.runner
    runner, deploy-      │   server)       │   ├─ nixosModules.deploy-target
    target, ab-image,    │                 │   ├─ nixosModules.ab-image
    overlay-nix, auto-   │                 │   ├─ nixosModules.overlay-nix
    update, secrets,     │                 │   ├─ nixosModules.auto-update
    workflows, actions)  │                 │   ├─ nixosModules.secrets
                         │                 │   └─ lib.mkDocs (consumer docs)
                         └─────────────────┘
                                 │
                                  ▼  runs on the Forgejo Actions runner
                             (the runner is declared via the nixtache runner
                              module, consumed by the infra machine — in this
                              reference workspace: `server`)
```

**Module layout** (`modules/runner/` — split by responsibility, all
contributions merge into one container via `mkMerge`):

| File | Owns |
|---|---|
| `default.nix` | Orchestrator: imports, container shell, identity options (`enable`, `forgejoUrl`, `containerName`, `package`, limits, `nixSettings`), base nix gc/optimise, host-side `container@<name>` limits. |
| `types.nix` | Shared option types (`knownHostEntry`, `instanceType`, `sshCredsType`, default GitHub known-hosts). |
| `store.nix` | Relocated store: `store.{path,hostBackup}`, custom `nix-daemon` + storage oneshot + socket, `BindPaths`. |
| `cache.nix` | Binary cache: `cache.*`, `secrets.cachePrivateKey`, in-container `nix-serve`, host-side nginx vhost. |
| `ssh.nix` | `flakeSshCreds` / `updateSshCreds`: key bindMounts + per-service `LoadCredential`. |
| `sandbox.nix` | `enableSandbox` / `additionalCapabilities` (sole owner of container caps), forced `nix.settings.sandbox`. |
| `known-hosts.nix` | `gitHost` / `extraKnownHosts`, in-container `services.openssh.knownHosts`. |
| `instances.nix` | `bot.*` + `instances.<name>`, `gitea-actions-runner` map, all `runner.envs`. |
| `deploy.nix` | `deploy.targets.<name>` map → job env `NIXTACHE_DEPLOY_TARGETS` + per-target key bind-mounts / `LoadCredential` (`deploy_ssh_<name>[.pub]`). |
| `ab.nix` | Runner-side A/B staging (`deploy.ab.*`): central staging dir + HTTPS distribution via the cache vhost, GPG manifest signing, retain-GC. |

The other nixtache modules live in sibling directories:

| Module | Owns |
|---|---|
| `modules/deploy-target/` | Target side of direct deploy: root `nixtache-apply.service` (activate → probe `criticalUnits` → rollback), polkit start-only rule, `nixtache-deploy` group + pointer dir, deploy-user provisioning with the SSH gate, Tier-0 health check, `ab.*` runtime (gating, partition provisioning). |
| `modules/ab-image/` | Build-time A/B image config: repart slots, UKI, sysupdate transfers, `system.image.{id,version}`, boot counting, GPG verify. |
| `modules/overlay-nix/` | Writable OverlayFS `/nix/store` (lower = RO image store, upper = writable) via `local-overlay-store`, so appliance targets can install packages at runtime. |
| `modules/auto-update/` | Unified auto-update replacing `system.autoUpgrade` (asserted): flake + ab-image paths, shared timer, reboot policy. |
| `modules/secrets.nix` | Secrets provider abstraction (`vars` + extensible `providers`). |

The public API and option surface are identical to the former monolith —
consumers and `tests/runner.nix` are unchanged. The NixOS `containers.<name>.config`
option merges every sub-module's contribution into one container evaluation
(see nixpkgs `nixos/modules/virtualisation/nixos-containers.nix` — its `merge`
concatenates all definitions into the inner `eval-config` modules list).

---

## Module contract

The runner module takes **paths** for secrets and **values** for everything
project-specific. It declares **no** `sops.secrets` and stores **no** files.

The registration token is **per-instance** (`instances.<name>.tokenFile`),
not global. Resource limits (`memoryMax`, `memoryHigh`, `timeoutStartSec`),
runner package, host packages, timeouts, log level, sandboxing, known hosts —
all options with sensible defaults.

> The full, always-up-to-date option reference is generated from the module
> source. Build it locally with `nix build .#optionsMarkdown` and read the
> result, or download the `nixtache-options` artifact from the latest CI run.

---

## Module → CI wiring

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

`*.user` is the git SSH **transport** user (server's `RUN_USER`, e.g.
`forgejo`/`git`) — not the bot account. The two bundles are **independent**:
`flakeSshCreds` gates private-input fetch, `updateSshCreds` gates update-flake
push. Typically the consumer points both at the same key files. If
`updateSshCreds = null`, `NIXTACHE_UPDATE_GIT_USER` is empty and
`update-flake.yml` **self-disables** (a guard step no-ops the job with a
warning). The bot's commit identity is separate (`bot.*`).

---

## Direct deploy (CI → machines)

nixtache ships a systemd-native deploy pipeline: CI builds a closure and
activates it on the machines you declare — no deploy-rs/colmena, no
sudo/doas/run0 on the targets. Design:
[`doc/specs/0001-direct-deploy.md`](doc/specs/0001-direct-deploy.md);
consumer guide: [`doc/migration/direct-deploy.md`](doc/migration/direct-deploy.md).

### Runner side: the target map

On the runner host, declare one entry per deployable machine; the attribute
name MUST equal the consumer's `nixosConfigurations.<name>` (the
`deploy-target` action pairs configs and targets by that name):

```nix
services.nixtache.runner.deploy.targets.desktop = {
  host = "desktop.example.com";                         # reachable address
  sshPrivateKey = config.sops.secrets.deploy-desktop-key.path;
  sshPublicKey  = config.sops.secrets.deploy-desktop-key-pub.path;
  method = "live";                                      # "live" (default) | "ab-image"
  # sshUser = "nixos-deploy"; sshPort = 22; timeout = 240; tags = [ ... ]; extraOptions = "...";
};
```

The map is serialized (minus secret paths — only a `hasKey` bool per target
ships) into the job env `NIXTACHE_DEPLOY_TARGETS`; the keys are exposed to
jobs via `LoadCredential` (`deploy_ssh_<name>[.pub]`).

### CI side: the reusable workflow

```yaml
# your .forgejo/workflows/deploy.yml
jobs:
  deploy:
    uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main
    secrets: inherit
```

The mode is derived from the branch inside the action (PR → `dry-activate`,
`main` → `switch`). Deploys are serialized per ref (concurrency group
`deploy-<ref>`, never auto-cancelled) and each target honours its `timeout`.

### Target side: `nixosModules.deploy-target`

Import it on **every** deploy target:

```nix
imports = [ nixtache.nixosModules.deploy-target ];

services.nixtache.deploy-target = {
  criticalUnits = [ "amneziawg-wg0.service" "forgejo.service" ];
  deployUser = {
    name = "nixos-deploy";
    authorizedKey = "ssh-ed25519 AAAA...";  # matches the runner's key for this target
  };
};
```

The module provisions a root-owned `nixtache-apply.service` (set profile →
`switch-to-configuration` → probe `criticalUnits` → re-activate the previous
closure on failure), polkit rules authorizing the deploy user to **start**
that one unit, the `nixtache-deploy` group owning the pointer dir, and a
Tier-0 health check gated on `boot-complete.target`.

### Methods: `live` vs `ab-image`

- **`live`** (default): the runner builds the toplevel, pushes the closure
  with `nix copy --to ssh://…`, drops a pointer file and triggers
  `nixtache-apply.service`.
- **`ab-image`**: the target boots A/B appliance images
  (`nixosModules.ab-image` + `deploy-target.ab.*`); the runner builds, signs
  and stages a `sysupdate-package` centrally (`deploy.ab.*` on the runner
  module), and the target's `systemd-sysupdate` writes the inactive slot and
  reboots. The runner host itself self-updates through the idle-gated
  `nixtache-ab-apply` unit.

### Security model

- The deploy user is a **system user** (uid < 1000, invisible on login
  screens) whose key is gated by `nixtache-ssh-gate` — an authorized_keys
  `restrict,command=` prefix allowing exactly the probe, `nix-store --serve`,
  the apply trigger and the A/B triggers; everything else is rejected.
- It may **start** `nixtache-apply.service` (polkit, start-only) and write
  the pointer file (`nixtache-deploy` group). No sudo/doas/run0 anywhere.
- It is added to `nix.settings.trusted-users` **unconditionally**: `nix copy
  --to ssh://…` pushes locally-built unsigned closures, which the daemon only
  imports for trusted users (nix.conf(5)) — a protocol requirement of the
  live path, not an optional privilege.

### Auto-update

`nixosModules.auto-update` replaces `system.autoUpgrade` (importing both is
asserted against): one shared timer, `method = "auto" | "flake" |
"ab-image"` (auto derives from the target type), and a `rebootPolicy`
(`never` / `if-needed` / `window`). The flake path builds the toplevel and
activates it through the same `nixtache-apply.service` — probe + rollback
apply to timer-driven updates exactly as to CI deploys; the ab path triggers
sysupdate. See
[`doc/specs/direct-deploy/09-auto-update.md`](doc/specs/direct-deploy/09-auto-update.md).

---

## Build sandboxing

The runner is a NixOS `systemd-nspawn` container. NixOS sets
`nix.settings.sandbox = true` by default, **but nspawn drops `CAP_SYS_ADMIN`
from the container's bounding set**, so `nix-daemon` inside cannot create the
user/mount namespaces + bind-mounts the sandbox needs. Worse: even when
`CAP_SYS_ADMIN` is granted back, nspawn's seccomp / private-users restrict the
`clone(CLONE_NEWUSER|CLONE_NEWNS)` the Nix sandbox needs — so the cap alone is
**not** sufficient on most nspawn setups, and `enableSandbox = true` produces
broken CI ("this system does not support the kernel namespaces required for
sandboxing"). The default is therefore `false` (working CI; the runner container
itself is the isolation boundary). Two options make the trade-off explicit:

| option | default | effect |
|---|---|---|
| `enableSandbox` | `false` | unprivileged container, `nix.settings.sandbox = false`. Working CI out of the box. |
| `enableSandbox` | `true` (opt-in) | grants `CAP_SYS_ADMIN`, forces `nix.settings.sandbox = true`, applies the daemon `/proc` remount fix (PrivateMounts + fresh procfs on both daemons). Use ONLY if you've verified the Nix sandbox works in your nspawn (host sysctl `kernel.unprivileged_userns_clone=1`, no `--private-users` conflict, seccomp allows the clone flags). |
| `additionalCapabilities` | `[]` | extra caps merged on top (e.g. `CAP_NET_ADMIN` for tunnel setup) |

**CI side — runtime probe, not config.** Whether builds actually run
sandboxed is detected per job by the
[`sandbox-probe`](.forgejo/actions/sandbox-probe/action.yml) action: it
builds a tiny probe derivation and exports `SANDBOX_OK=1` (sandbox usable)
or `SANDBOX_OK=0` (fall back). Every build action (`flake-validation`,
`rebuild-configurations`, `rebuild-devshells`, `generate-docs`,
`deploy-target`) and nixtache's own `ci.yml` append `--no-sandbox` when
`SANDBOX_OK` ≠ 1 — a runner whose sandbox is broken (or not yet rebuilt with
the fix) self-heals to `--no-sandbox` instead of failing.

The module still exports a static `HAS_SANDBOX_CAP` env (mirrors
`enableSandbox`), but nothing consumes it — it is legacy; `SANDBOX_OK` from
`sandbox-probe` is the operative flag.

> **Sandbox-in-nspawn is a known hard problem.** The default `false` trades
> build-level isolation for reliability. Making `true` actually work requires
> host-side setup (sysctl, nspawn flags) that nixtache does not yet automate —
> tracked as a follow-up (important for cross-compile purity via binfmt).

> **Deploy chicken-and-egg:** any change to `enableSandbox` / caps applies
> only after the server is rebuilt with the updated module, so a first-time
> rollout needs one manual `nixos-rebuild switch` (or an `ab-image` deploy)
> on the server. The runtime probe means CI stays green on both sides of that
> switch.

---

## Secrets providers

nixtache separates **what a secret is** (a materialised path the modules read)
from **how it got there** (a provider). The end result is a uniform namespace:

```nix
services.nixtache.secrets.vars.<name>   # type: path, internal
```

Populated by one or more **providers** — and any combination may be active at
once (e.g. ssh for git+ssh-fetched values + vault for runtime-pulled ones +
forgejo for workflow-level vars):

```nix
services.nixtache.secrets.providers = {
  ssh.enable     = true;   # planned: git+ssh private flake (nixos-private pattern) / SSH key paths
  forgejo.enable = false;  # planned: Forgejo CI variables (${{ secrets.X }})
  vault.enable   = false;  # planned: HashiCorp Vault (vault-agent / systemd-vaultd) — intended PRIMARY
  systemd.enable = false;  # planned: systemd LoadCredential / credentials dir
};
```

**Status:** today the runner module consumes paths via its own
`services.nixtache.runner.*` options (the stable direct contract — path-based,
backend-agnostic: works with sops, agenix, vault-agent, systemd LoadCredential,
…). The `vars` namespace is the target providers write into; future runner
wiring will let it read from `vars` instead of (or alongside) its direct
options. Consumers can already populate `vars` manually for cross-module
secret references.

Adding a provider is purely additive: it only appends to `vars`, so existing
providers and direct assignments keep working. See
[`modules/secrets.nix`](modules/secrets.nix) for the contract.

---

## Documenting your flake

nixtache ships a helper so consumers generate documentation for **their own**
`nixosConfigurations` and `devShells`, and a reusable workflow that builds +
uploads it in CI.

### 1. Wire `nixtache.lib.mkDocs` into your `packages`

```nix
# your flake.nix
outputs = { self, nixpkgs, nixtache, ... }: {
  nixosConfigurations = {
    server  = ...;
    desktop = ...;
  };
  devShells.x86_64-linux = {
    default   = ...;
    vrc-shell = ...;
  };

  packages.x86_64-linux = nixtache.lib.mkDocs {
    inherit (nixpkgs) lib;
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    nixosConfigurations = self.nixosConfigurations;        # optional
    devShells = self.devShells.x86_64-linux;               # optional
    # Scope each machine's option reference to the given top-level paths.
    # Omit for the full NixOS option reference (large but searchable).
    optionPrefixes = [ "services.nixtache" "services.myapp" ];
    # Optional: fail the docs build on any option without a `description`
    # (same policy nixtache applies to itself). Default false — missing
    # descriptions are then build-log warnings.
    docStrictMode = true;
  };
};
```

This exposes:
- `packages.<system>.configurationDocs-<machine>` — per-machine option
  reference (CommonMark, via `pkgs.nixosOptionsDoc`, scoped by `optionPrefixes`).
- `packages.<system>.devShellDocs` — markdown listing each devShell + its
  `meta.description` (set `meta.description` on your `mkShell` calls).
- `packages.<system>.docs` — the above concatenated; **the artifact CI uploads**.
- `packages.<system>.default` — alias of `docs`.

Verify locally: `nix build .#docs` and read the result.

### 2. Add a thin workflow wrapper

```yaml
# your .forgejo/workflows/docs.yml
name: Docs
on:
  push:
    branches: [ main ]
  pull_request:
  workflow_dispatch:

jobs:
  docs:
    uses: nixops/nixtache/.forgejo/workflows/docs.yml@main
    with:
      attributes: "docs"          # flake attr(s) to build; default "docs"
      artifact-name: "docs"       # uploaded artifact name
    secrets: inherit
```

After CI runs, the `docs` artifact contains your generated documentation
(`docs.md` + any per-machine references if you listed multiple `attributes`).
To also build per-machine refs, set
`attributes: "docs configurationDocs-server configurationDocs-desktop"`.

> The reusable workflow runs in the **caller's** context — `actions/checkout`
> checks out your repo, so `nix build .#docs` sees your flake. In the Forgejo
> UI a reusable call renders as two jobs (`docs` 0s caller + `docs-1` work);
> expected.

### Tips

- **Tag your shells:** `mkShell { meta.description = "VRChat SDK (Python/C++/Qt)"; }`
  — `devShellDocs` surfaces it. Shells without it are listed with a hint.
- **Scope the reference:** `optionPrefixes` keeps each machine's reference
  focused on your namespaces. Without it you get the full ~6000-option NixOS
  reference (useful as an offline manual, large).
- **Custom outputs:** nothing stops you adding your own `packages.<system>.X`
  and pointing `attributes` at it.

---

## CRITICAL: this repo must stay `sha1`

Nix 2.34.8 cannot fetch `sha256` git repos — it parses the rev as sha1
(40 chars) and rejects sha256 revs (64 chars). Both `git+ssh` and tarball
fetchers break. See [NixOS/nix#9980](https://github.com/NixOS/nix/issues/9980),
PR [#14526](https://github.com/NixOS/nix/pull/14526) (draft, not merged).

- Local repo: `git config extensions.objectFormat` must be **unset** (= sha1).
- Remote `nixops/nixtache` on Forgejo: created sha1. Object format is
  immutable on a bare repo — changing it requires **delete + recreate**.
- If you ever re-`git init --object-format=sha256`, every consumer's
  `nix flake lock` breaks.

---

## Commands

```bash
# Validate this flake (note: repo must be sha1, see above)
nix flake check --show-trace --all-systems

# Build + read the generated option reference for this flake
nix build .#optionsMarkdown && cat ./result
nix build .#optionsHTML                    # browsable standalone HTML

# Run a pure-eval module test suite (prints an ok/FAIL report).
# Suites: runner, deploy-target, ab-image, mkDocs, ab-existing,
#         ab-contract, auto-update
nix build .#checks.x86_64-linux.runner && cat ./result

# Run a KVM VM suite — needs a KVM host and is NOT run by CI
# (`nix flake check` skips vmTests entirely). E.g.:
nix build .#vmTests.x86_64-linux.ab-deploy
nix build .#vmTests.x86_64-linux.overlay-nix-vm

# Evaluate the runner contract standalone (no host needed) — sanity check
nix-instantiate --parse modules/runner/default.nix > /dev/null && echo OK
```

### Consumer commands

```bash
# Build your docs locally
nix build .#docs && cat ./result

# Evaluate a nixtache option against your host
nix eval --raw .#nixosConfigurations.server.config.services.nixtache.runner.forgejoUrl
```

---

## Reusable workflow mechanics (Forgejo)

- A reusable workflow (`on: workflow_call`) invoked from a caller repo runs
  in the **caller's** checkout context (`actions/checkout@v4` checks out the
  caller, so `nix flake show` / `nix build .#X` see the caller's flake).
- To resolve **this repo's** composite actions, the reusable workflow checks
  out `nixops/nixtache` into `.nixtache/` and uses
  `./.nixtache/.forgejo/actions/<name>`. (Robust against Forgejo's cross-repo
  action path resolution.)
- In the Forgejo UI a reusable call renders as two jobs: `<name>` (0s caller)
  and `<name>-1` (the work). Expected.

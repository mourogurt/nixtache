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
nixtache.nixosModules.forgejo-runner   # (or .default alias)
```

- **`nixosModules.forgejo-runner`** — `services.nixtache.forgejo-runner`:
  a NixOS container running `gitea-actions-runner` (forgejo-runner) with a
  configurable nix store location (`store.path`: `"/"` reuses the container's
  system nix-daemon; any other base like `/srv` relocates the store to
  `<path>/nix` via a custom `nix-daemon` + storage oneshot), a `nix-serve-ng`
  binary cache, and an nginx vhost. All project-specific values are options;
  **secrets are `types.path`, supplied by the consumer**.
- **`checks.x86_64-linux.forgejo-runner`** (alias `.default`) — pure-evaluation
  tests for the `store.path` contract (`/`, `/srv`, empty). Build with
  `nix build .#checks.x86_64-linux.forgejo-runner`.
- **`.forgejo/workflows/{nix-check,update-flake}.yml`** — reusable workflows
  (`on: workflow_call`) for consumer repositories.
- **`.forgejo/workflows/ci.yml`** — nixtache's **own** CI: on push/PR to
  `main`, runs `nix flake check` (which builds `checks.*`, i.e. the module
  tests) and prints the test report. Not reusable — nixtache has no
  `nixosConfigurations`/`devShells`, so it deliberately does not call
  `rebuild-configurations`/`rebuild-devshells`.
- **`.forgejo/actions/{ssh-setup,flake-validation,rebuild-configurations,rebuild-devshells}`**
  — reusable composite actions.
- **`doc/migration-plan.md`** — the migration plan + architectural decisions
  (Q1–Q5) that shaped this repo.

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
services.nixtache.forgejo-runner = {
  enable        = true;
  forgejoUrl    = "http://localhost:3000";          # Forgejo URL (shared by all instances)
  containerName = "forgejo-runner";                  # NixOS container name
  package       = pkgs.forgejo-runner;               # forgejo-runner package (default)
  instances     = {                                 # one gitea-runner-<name> per attr; each needs its own tokenFile
    default = { name = "nixos-container-runner"; tokenFile = config.sops.secrets.runner-token-default.path; };
    test    = { labels = [ "nixos:test" ]; tokenFile = config.sops.secrets.runner-token-test.path; };
  };
  cache = { enable = true; domain = "bincache.example.com"; port = 5000; };
  store.path = "/srv";                           # base dir; store lives at <path>/nix. "/" = system nix-daemon
  store.hostBackup = "/srv/bincache";            # host dir mounted at store.path
  nixSettings   = { substituters = [...]; trusted-public-keys = [...]; max-jobs = 1; cores = 8; };
  gitHost       = { name = "forgejo_ed25519"; hostNames = [ "git.example.com" "10.0.0.1" "localhost" ]; publicKey = "ssh-ed25519 AAAA..."; };
  extraKnownHosts = [ { name = "github_ed25519"; hostNames = [ "github.com" ]; publicKey = "ssh-ed25519 AAAA..."; } ];
  secrets = {
    # Shared across instances. The bot SSH key pair is OPTIONAL: omit both for
    # build-only / test instances (no git push-back → no fbot wiring).
    sshPrivateKey   = config.sops.secrets.forgejo-private-key.path;  # optional (null = disabled)
    sshPublicKey    = config.sops.secrets.forgejo-public-key.path;   # optional (null = disabled)
    cachePrivateKey = config.sops.secrets.cache-private-key.path;
    # Any backend works: paths can come from sops, agenix, vault-agent,
    # systemd LoadCredential, etc. The module is backend-agnostic by design.
  };
};
```

The registration token is **per-instance** (`instances.<name>.tokenFile`), not
global. Resource limits (`memoryMax`, `memoryHigh`, `timeoutStartSec`), runner
package, host packages, timeouts, log level are all options with sensible
defaults.

## Consumer pattern

1. Add the flake input (`git+ssh`, see above) and import
   `nixtache.nixosModules.forgejo-runner` into the host's modules.
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
nix-instantiate --parse modules/forgejo-runner.nix > /dev/null && echo OK

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

## Nix style

Follows the workspace conventions (`../AGENTS.md`): 2-space indent, kebab-case
files, camelCase vars, `{ config, lib, pkgs, ... }:` signature, `mkIf`/
`mkMerge`/`mkOption` with `defaultText`, `lib.literalMD`/`lib.literalExpression`
for non-trivial defaults.

## TODO / out of scope here

- **Deploy contract** (`deploy.yml` + `deploy-target` action) is defined in
  `doc/migration-plan.md` (section "Контракт деплоя") as stubs; implementation
  is a separate task (deploy tool choice, target SSH auth, rollback strategy).
- **Secret provider presets** (`nixtache.secrets.providers.{sops,vault,systemd}`)
  are planned sugar over the path-based core (decision Q4=B in the migration
  plan). The path-based core is the stable contract today.

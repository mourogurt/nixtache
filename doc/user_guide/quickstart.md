# Quickstart

Everything a consumer needs to adopt nixtache: add the input, import the
runner module with secrets you own, and replace your workflows with thin
wrappers. Deep wiring internals live in
[`doc/technical_details/`](../technical_details/); the direct-deploy feature
has its own guide ([`deploy.md`](deploy.md)).

- What you import: six NixOS modules — `nixtache.nixosModules.runner` (the
  Actions runner in a NixOS container), `.deploy-target` (receive direct
  deploys), `.ab-image` (A/B appliance image config), `.overlay-nix`
  (writable store overlay for appliances), `.auto-update` (unified
  auto-update channel), `.secrets` (secrets-provider abstraction).
- What gets generated: option references for this flake AND helpers
  (`nixtache.lib.mkDocs`) so consumers document their own configurations and
  devShells — see [`docs-generation.md`](docs-generation.md).
- What nixtache never stores: secrets and project-specific values (hosts,
  domains, keys). All of that is supplied by the consumer via module options.

## 1. Add the flake input

```nix
inputs.nixtache.url = "git+ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git";
```

## 2. Import the runner module

The module takes **paths** for secrets and **values** for everything
project-specific. It declares **no** `sops.secrets` — you own the secret
declarations and feed the resulting paths in:

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

Secret paths can come from sops, agenix, vault-agent, systemd LoadCredential,
etc. — the module is backend-agnostic by design.

### Module contract notes

- The registration token is **per-instance** (`instances.<name>.tokenFile`),
  not global; each instance needs its own token file.
- Resource limits (`memoryMax`, `memoryHigh`, `timeoutStartSec`), runner
  package, host packages, timeouts, log level, sandboxing, known hosts — all
  options with sensible defaults. The full always-up-to-date reference is
  generated from the module source: `nix build .#optionsMarkdown` inside this
  repo, or the `nixtache-options` CI artifact.
- Multi-instance: one `gitea-runner-<name>` service per `instances.<name>`
  attribute (`instances.test = { labels = [ "nixos:test" ]; tokenFile = …; }`).
- How these values reach CI jobs (`runner.envs`, `LoadCredential`) is
  documented in
  [`doc/technical_details/module-ci-wiring.md`](../technical_details/module-ci-wiring.md).

> **Role model (vendor-agnostic).** nixtache does not fix machine roles. The
> **infra machine** runs the Forgejo Actions runner
> (`services.nixtache.runner`); **target machines** receive deploys from the
> deploy feature ([`deploy.md`](deploy.md)). Any names like `server` /
> `desktop` / `laptop` in examples are just examples.

## 3. Replace your workflows with wrappers

Delete your `.forgejo/workflows/*.yml` bodies and your `.forgejo/actions/`;
call nixtache's reusable workflows instead:

```yaml
# .forgejo/workflows/nix-check.yml
jobs:
  check-flake:
    uses: nixops/nixtache/.forgejo/workflows/nix-check.yml@main
    secrets: inherit
```

Available reusable workflows: `nix-check` (flake validation + rebuilds),
`deploy` ([deploy.md](deploy.md), requirements:
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)),
`docs`
([docs-generation.md](docs-generation.md)), `update-flake` (scheduled flake
input bump with SSH-signed bot commits; self-disables when the runner's
`updateSshCreds` is null). See
[`doc/technical_details/workflow-mechanics.md`](../technical_details/workflow-mechanics.md)
for how reusable workflows resolve actions.

## 4. (Optional) Generate your flake's docs

See [`docs-generation.md`](docs-generation.md).

## Consumer commands

```bash
# Build your docs locally
nix build .#docs && cat ./result

# Evaluate a nixtache option against your host
nix eval --raw .#nixosConfigurations.server.config.services.nixtache.runner.forgejoUrl
```

Reference consumer: `codemaster/nixos-configuration`
(`server/services/forgejo-runner.nix` is the instance). Migration from older
nixtache versions (including BREAKING changes): [`migration.md`](migration.md).

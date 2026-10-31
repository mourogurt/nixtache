# Quickstart

Everything a consumer needs to adopt nixtache: add the input, import the
runner module with secrets you own, and replace your workflows with thin
wrappers. Deep wiring internals live in
[`doc/technical_details/`](../technical_details/); the direct-deploy feature
has its own guide ([`deploy.md`](deploy.md)).

- What you import: five NixOS modules — `nixtache.nixosModules.runner` (the
  Actions runner in a NixOS container), `.deploy-target` (receive direct
  deploys), `.ab-image` (A/B appliance image config), `.overlay-nix`
  (writable store overlay for appliances), `.auto-update` (unified
  auto-update channel).
- What gets generated: option references for this flake AND helpers
  (`nixtache.lib.mkDocs`) so consumers document their own configurations and
  devShells — see [`docs-generation.md`](docs-generation.md).
- What nixtache never stores: secrets and consumer-specific Forgejo, cache or
  deploy endpoints. Those are supplied by the consumer via module options.

## 1. Add the flake input

```nix
inputs.nixtache.url = "git+ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git";
```

## 2. Import the runner module

The module takes **paths** for secrets and **values** for everything
project-specific. It declares **no** `sops.secrets` — you own the secret
declarations and feed the resulting paths in. Pass the flake input to the
NixOS configuration through `specialArgs = { inherit nixtache; };` (or import
it from the flake's lexical scope):

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
    instances.default = {                         # one Forgejo registration per instance: uuid + bare token
      uuid      = "c9e50be9-a7c3-4aee-ba35-624c4ff8c519";
      tokenFile = config.sops.secrets.runner-token-default.path;
    };
    cache = { enable = true; domain = "bincache.example.com"; port = 5000; };
    store.path      = "/srv";       # base dir; store lives at <path>/nix. "/" = system nix-daemon
    store.hostBackup = "/srv/bincache";
    gitHost = { name = "forgejo_ed25519"; hostNames = [ "code.zinzaguras.ru" ]; publicKey = "ssh-ed25519 AAAA..."; };
    secrets.cachePrivateKey = config.sops.secrets.cache-private-key.path;
  };
}
```

`gitHost.hostNames[0]` is the SSH push host used by `update-flake`. Every
other SSH host in `flake.lock` must also have a matching key in the effective
known-hosts configuration (`gitHost` or `extraKnownHosts`). Secret paths can
come from sops, agenix, vault-agent, systemd LoadCredential, etc. — the module
is backend-agnostic by design.

### Module contract notes

- Each instance is its **own Forgejo registration**: a uuid + token pair
  (`instances.<name>.uuid` + `instances.<name>.tokenFile`), obtained from
  Forgejo when the registration is created. The runner name is configured in
  Forgejo, not through an `instances.<name>.name` option. See "Registering
  runner instances" below.
- Resource limits (`memoryMax`, `memoryHigh`, `memorySwapMax`, `cpuWeight`,
  `ioWeight`, `timeoutStartSec`), runner package, host packages, timeouts,
  log level, sandboxing, known hosts — all options with sensible defaults.
  The full always-up-to-date reference is generated from the module source:
  `nix build .#optionsMarkdown` inside this repo, or the `nixtache-options`
  CI artifact.
- Multi-instance: one `forgejo-runner-<name>` service per **enabled**
  `instances.<name>` attribute (`instances.test = { uuid = …; labels = [
  "test:host" ]; tokenFile = …; }`).
- How these values reach CI jobs (`runner.envs`, `LoadCredential`) is
  documented in
  [`doc/technical_details/module-ci-wiring.md`](../technical_details/module-ci-wiring.md).

### Registering runner instances

The module wires the upstream `services.forgejo-runner` registration model:
each `instances.<name>` authenticates with a **uuid + token pair** created in
Forgejo beforehand and has its own uuid and token. The runner **name** is
fixed in Forgejo when the registration is created; it is not configured on
the module side.

The token file holds the **bare token** — just the token string, no
`TOKEN=` prefix, no environment-file syntax. The uuid is not a secret (the
generated runner config carries it verbatim, in the world-readable Nix
store), so keep it in the plain configuration; only the token goes through
your secret backend (sops/agenix/vault/…), as with every other `*File`
option.

Requirements (canonical):
[`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md).

#### New registration

1. In Forgejo, create a runner registration in the scope the runner should
   serve (per project/repository or per organisation) — see Forgejo's
   [runner registration docs](https://forgejo.org/docs/latest/admin/actions/registration/).
   Forgejo shows the registration's **uuid** and **token**.
2. Put the uuid into `services.nixtache.runner.instances.<name>.uuid`
   (plain config) and the token — bare, nothing else — into the secret file
   behind `instances.<name>.tokenFile`.
3. Deploy; the `forgejo-runner-<name>` service starts picking up jobs.

Requires a Forgejo instance that supports the uuid + token registration
model (i.e. offers the registration UI/API above). If yours predates it,
upgrade Forgejo first.

#### Migrating from the old self-registration model

If you ran a pre-26.11 runner: the old module's options are gone, so before
the first deploy of the updated module each instance needs its uuid + token
pair in hand. The pair of an already-registered runner can be recovered
from its old state instead of re-registering:

1. While the old container still runs, read the runner's `.runner` file —
   inside the container, at `/var/lib/gitea-runner/<name>/.runner`:

   ```bash
   sudo nixos-container run <containerName> -- cat /var/lib/gitea-runner/<name>/.runner
   ```

   It is JSON; take the `uuid` and `token` values.
2. Set `instances.<name>.uuid` to the uuid; rewrite the instance's secret
   file to contain **just the token** (strip the old `TOKEN=` prefix and
   any other lines); remove any `instances.<name>.name` assignment (the
   option no longer exists and now fails evaluation).
3. Deploy and verify the `forgejo-runner-<name>` services pick up jobs.

The old in-container state directory `/var/lib/gitea-runner/` stays unused
after the cutover and can be removed by hand; the module does not touch it.
Rolling back means rolling nixpkgs back too (the old module no longer
exists there) — in practice: don't migrate the configuration until the
uuid + token pair is in hand.

### Sizing the container

The defaults (`memoryMax = "16G"`, `memoryHigh = "14G"`) budget the container
for a host **shared** with other services. On a dedicated CI host, raise both
explicitly (keep `memoryHigh` ~2G below `memoryMax` — throttling starts
there, before the hard limit kills).

Large builds survive a tight RAM budget through **host swap**: with zram
enabled, chromium-class link peaks compress into swap instead of dying (the
module sets no swap ceiling by default — `memorySwapMax` exists to protect
co-hosted services' swap, not to enable survival). On a host **without**
swap, lower `nixSettings.cores` or raise `memoryMax` for chromium-class
builds. `cpuWeight`/`ioWeight` shape contention with co-hosted services
without capping the build on an idle host.

> **Upgrade note.** The defaults changed from `"60G"`/`"58G"` to
> `"16G"`/`"14G"`. If you relied on the old implicit budget, pin the previous
> values explicitly.

Internals (cgroup paths, kill diagnostics): see
[`doc/technical_details/resources.md`](../technical_details/resources.md).

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
name: Check
on:
  push:
    branches: [ main ]
  pull_request:
  workflow_dispatch:

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
`updateSshCreds` is null — fetching private inputs additionally requires
`flakeSshCreds`; the guard validates the update key before the pipeline runs,
see [module-ci-wiring.md](../technical_details/module-ci-wiring.md)). See
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
(`server/services/forgejo-runner.nix` is the instance).

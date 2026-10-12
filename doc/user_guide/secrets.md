# Secrets

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

## Status

Today the runner module consumes paths via its own
`services.nixtache.runner.*` options — the stable direct contract:
path-based, backend-agnostic (works with sops, agenix, vault-agent, systemd
LoadCredential, …; see [`quickstart.md`](quickstart.md)). The `vars`
namespace is the target providers write into; future runner wiring will let
it read from `vars` instead of (or alongside) its direct options. Consumers
can already populate `vars` manually for cross-module secret references.

Adding a provider is purely additive: it only appends to `vars`, so existing
providers and direct assignments keep working.

## Notes

- The repository itself stores **no secrets** (encrypted ones included) —
  everything secret is supplied by the consumer as paths.
- Provider contract details: [`modules/secrets.nix`](../../modules/secrets.nix).
- The concrete provider implementations are roadmap work — see AGENTS.md
  "TODO / out of scope".

# Secrets

nixtache separates **what a secret is** (a materialised path a module reads)
from **how it got there** (a provider). The provider abstraction exposes an
internal namespace:

```nix
services.nixtache.secrets.vars.<name>   # type: path
```

Consumers may populate `vars` manually for references from their own modules.
`providers.<name>` is an extensible configuration registry; nixtache currently
ships no concrete provider implementations, so enabling a provider name does
not materialize secrets or populate `vars`.

The runner consumes secret paths through its direct
`services.nixtache.runner.*` options. This stable contract is backend-agnostic
and works with sops, agenix, vault-agent, systemd LoadCredential and similar
mechanisms; see [`quickstart.md`](quickstart.md). The runner does not read
`services.nixtache.secrets.vars`.

A provider implementation appends to `vars`, allowing multiple providers and
manual assignments to coexist. Provider contract:
[`modules/secrets.nix`](../../modules/secrets.nix).

The repository itself stores **no secrets** (encrypted ones included) — all
secret material is supplied by the consumer.

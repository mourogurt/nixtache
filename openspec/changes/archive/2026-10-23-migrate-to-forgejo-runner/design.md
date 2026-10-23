# Design

## Context

See `proposal.md` — Why. The upstream `services.forgejo-runner` module
(nixpkgs `services/continuous-integration/forgejo-runner.nix`) is a redesign
of `services.gitea-actions-runner`, which nixpkgs 26.11 replaced with a hard
assertion stub. Key upstream differences that shape this design:

- **Registration**: `url`/`tokenFile`/`name` per instance are gone. A runner
  no longer self-registers with a registration token; it authenticates with
  a uuid + token pair created in Forgejo, configured as
  `settings.server.connections.<conn>.{url,uuid,token}` and, for
  file-based secrets, `secrets.server.connections.<conn>.token_url`
  (templated into settings via systemd `LoadCredential=`).
- **Units**: `gitea-runner-<name>` → `forgejo-runner-<name>`
  (`utils.escapeSystemdPath` on the instance name; identity for the simple
  names nixtache documents), state dir `/var/lib/forgejo-runner/<name>`.
- **Identity**: the service is a pure `DynamicUser` with no static
  `User=` — the old stable `gitea-runner` account no longer exists. The
  dynamic user is NSS-visible under the unit's name (nss-systemd), i.e.
  `forgejo-runner-<name>`.
- **What survives unchanged**: free-form `settings` (verified against
  forgejo-runner's `config.example.yaml`: `runner.envs`, `runner.timeout`,
  `runner.shutdown_timeout`, `log.level`, `log.job_level` all exist),
  `hostPackages`, per-instance `enable`, and `package`
  (`forgejo-runner`).

nixtache consumers evaluate the container against their own nixpkgs, so
staying on `gitea-actions-runner` is impossible — the assertion fires
before any module code runs. Vendoring the old module is not an option
either: nixtache deliberately passes no nixpkgs into the container contract
(`flake.nix` documents the input as non-leaking).

## Goals / Non-Goals

Goals:

- A consumer on nixpkgs 26.11+ can evaluate and deploy the runner module.
- Keep nixtache's option surface as stable as the new model allows: only
  what upstream removed/renamed changes.
- One-time, documented consumer migration per runner instance.

Non-Goals:

- Exposing upstream's multi-connection feature (one runner serving several
  Forgejo instances). nixtache keeps a single module-global `forgejoUrl`
  and names the connection `default`. Revisit only if a consumer need
  appears.
- Supporting Gitea (as opposed to Forgejo) servers: the forgejo-runner
  binary still speaks to Gitea, but the module wires Forgejo-style
  registration; the `package` option remains overridable for experiments.
- Migrating the container's old `/var/lib/gitea-runner` state automatically
  (no imperative state surgery from a NixOS module).

## Decisions

### D1: Target `services.forgejo-runner` directly, no compat shim

Rewrite `instances.nix`'s container config onto the new option tree
(`settings.server.connections.default.*`, `secrets...token_url`,
`settings.runner.labels`). Alternative — a shim mapping nixtache options
onto the removed `url`/`tokenFile`/`labels` (upstream keeps rename/remove
compat aliases) — was rejected: `tokenFile` has no automatic mapping (the
upstream removal message demands uuid extraction), and relying on
deprecated aliases would only defer the same breakage.

### D2: `instances.<name>` surface — add `uuid`, drop `name`, keep `tokenFile`/`labels`/`enable`

- `uuid` (required `types.str`): the runner UUID from Forgejo.
- `tokenFile` (`types.path`, required): semantics change — bare token in
  the file, no `TOKEN=` prefix. Keeping the option name minimizes consumer
  churn (the sops/vars plumbing behind it is unchanged); the description
  and the migration doc carry the format change.
- `name` is dropped from `instanceType` (setting it then fails evaluation,
  as the spec requires). Upstream removed it because runners no longer
  self-report names; re-exposing a no-op would lie to consumers.
- `labels` stays, forwarded to `settings.runner.labels` (upstream's renamed
  location) with the same `[ "nixos:host" ]` default.

Connection name is the module-level constant `default`: `forgejoUrl` is
already module-global, so per-instance connections would add surface for
nothing.

### D3: Token delivery stays a read-only bind mount + systemd credential

The existing pattern — host `tokenFile` bind-mounted at
`/var/secrets/runner/<iname>/token` — is kept and pointed at the new
module's `secrets.server.connections.default.token_url`. The container
boundary stays the only host↔container secret channel; no format sniffing,
no EnvironmentFile.

### D4: trusted-users switch to the NSS-visible dynamic service users

`default.nix`'s container base sets
`trusted-users = [ "root" "gitea-runner" "@users" ]`. The `gitea-runner`
entry is replaced by `forgejo-runner-<iname>` for every enabled instance,
appended from `instances.nix` (list options merge across the container
config's mkMerge contributors, so the base keeps `root`/`@users` and the
instance list stays with its owner). Alternative — dropping the entry and
relying on `@users` — rejected: dynamic users are not members of `users`,
and untrusted nix clients cannot use the configured substituters or copy
closures out of the store (`nix copy --to` in direct-deploy jobs would
break).

### D5: Service-name rewrites are mechanical, owned per sub-module

`ssh.nix`, `store.nix`, `deploy.nix`, `ab.nix` attach LoadCredential /
BindPaths / ordering to `gitea-runner-<iname>` units; each rewrites its own
`nameValuePair` prefix to `forgejo-runner-${iname}`. No shared helper —
the prefix is one line per site and a helper would couple five
sub-modules for a string. `escapeSystemdPath` is not applied: nixtache
instance names are attrset keys documented as simple identifiers, and the
four sites must agree with the upstream unit name; a name needing escaping
would be a new (undocumented) use case — covered instead by a test
asserting the generated unit names exist for the documented simple names.

### D6: `package` description updated, option kept

`package` still defaults to `pkgs.forgejo-runner` and still flows to the
in-container module. The description loses its `gitea-actions-runner`
wording (the module it referenced no longer exists) and notes the override
target is `services.forgejo-runner.package`.

## Risks / Trade-offs

- [NSS resolution of `forgejo-runner-<name>` inside the container fails, so
  jobs run as untrusted nix clients] → Mitigation: the dynamic-user name is
  synthesized by nss-systemd from the unit name, same mechanism the old
  module's stable `gitea-runner` name relied on; if a runtime check
  (consumer vmtest or first deploy) disproves it, fall back to documenting
  `nix.settings.trusted-users` UIDs is impossible (dynamic) — the escape
  hatch is the upstream `runtimes.host` plumbing or a unit drop-in via
  `systemd.services."forgejo-runner-<name>".serviceConfig` outside this
  module. Pure-eval tests can only assert the list contents, not NSS
  behavior — flagged here deliberately.
- [Consumers miss the migration step and deploy with a stale `TOKEN=...`
  file] → Mitigation: the runner service fails closed (auth error, visible
  in job logs), the user guide carries the extraction walkthrough, and the
  `tokenFile` option description states the bare-token contract where the
  consumer will actually see it.
- [Forgejo instance predates the uuid + token registration model] →
  Mitigation: documented as a hard requirement in the migration section;
  upgrading Forgejo is a consumer action outside this change.
- [Old `/var/lib/gitea-runner` state lingers in the container] → Trade-off:
  harmless (unused by the new unit); the migration doc mentions it can be
  removed after the cutover. No module-side cleanup.

## Migration Plan

1. Merge/deploy this change (module + docs together, one flake input bump).
2. Per runner instance, before the first activation of the new container:
   read `/var/lib/gitea-runner/<name>/.runner` inside the still-running old
   container (`machinectl shell`), extract `uuid` and `token`.
3. Consumer config: set `instances.<name>.uuid`, rewrite the secret file to
   the bare token, remove any `instances.<name>.name`.
4. Deploy; verify `forgejo-runner-<name>` services pick up jobs.
5. Rollback strategy: plain NixOS rollback — but note the old module no
   longer exists in nixpkgs 26.11, so rollback requires rolling nixpkgs
   back too. The real rollback is "don't migrate the config until the uuid
   + token pair is in hand".

## Open Questions

- None. (The trusted-users NSS assumption is recorded as a risk with an
  escape hatch, not an open question — it does not change the approach.)

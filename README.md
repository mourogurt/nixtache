# nixtache

Reusable, **vendor-agnostic** NixOS CI/CD flake. Provides the Forgejo Actions
runner as a NixOS module, a binary cache, a secrets-provider abstraction, a
direct-deploy pipeline (CI → your machines), and the reusable Forgejo
workflows + composite actions that build, validate and document consumer
flakes. Any project can consume it **without forking**.

nixtache stores **no secrets** and hardcodes **no** hosts/domains — all of
that is supplied by the consumer via module options. Start with the
[quickstart](doc/user_guide/quickstart.md).

## Repository map

### NixOS modules (`nixosModules.*`)

| Module | What it gives you |
|---|---|
| [`runner`](doc/user_guide/quickstart.md) | `services.nixtache.runner`: the Forgejo Actions runner (`gitea-actions-runner`, multi-instance) inside a NixOS container, with a configurable/relocatable nix store, an `nix-serve-ng` binary cache + nginx vhost, and credential wiring for private flake inputs and deploy keys. |
| [`deploy-target`](doc/user_guide/deploy.md) | `services.nixtache.deploy-target`: the receiving side of direct deploy — root `nixtache-apply.service` (activate → probe `criticalUnits` → rollback), polkit start-only rules, gated deploy user, Tier-0 health check. Import on every deploy target. |
| [`ab-image`](doc/user_guide/deploy.md) | `services.nixtache.ab-image`: build-time A/B appliance image config (repart slots, UKI, sysupdate transfers, boot counting, GPG verify). |
| `overlay-nix` | `services.nixtache.overlay-nix`: writable OverlayFS on `/nix/store` so image-based targets can install packages at runtime. |
| [`auto-update`](doc/user_guide/auto-update.md) | `services.nixtache.auto-update`: unified auto-update channel replacing `system.autoUpgrade` — flake and A/B paths, one timer, reboot policy. |
| [`secrets`](doc/user_guide/secrets.md) | `services.nixtache.secrets`: secrets-provider abstraction (`vars` + extensible `providers`). |

### Reusable workflows (`.forgejo/workflows/`) and actions

| Workflow | Purpose |
|---|---|
| `nix-check.yml` | validate the caller flake + rebuild all its `nixosConfigurations` and devShells |
| `deploy.yml` | direct deploy of the caller's configurations to their targets |
| `docs.yml` | build + upload the caller's generated documentation |
| `update-flake.yml` | scheduled flake-input bump with an SSH-signed bot commit |
| `ci.yml` | nixtache's **own** CI (not reusable) |

Composite actions: `ssh-setup`, `sandbox-probe`, `flake-validation`,
`rebuild-configurations`, `rebuild-devshells`, `generate-docs`,
`deploy-target`. How they resolve at run time:
[`doc/technical_details/workflow-mechanics.md`](doc/technical_details/workflow-mechanics.md).

### Other outputs

- `lib.mkDocs` — consumer docs helper (per-machine option references +
  devShell listings): [`doc/user_guide/docs-generation.md`](doc/user_guide/docs-generation.md).
- `packages.<system>.optionsMarkdown` / `.optionsJSON` / `.optionsHTML`
  (`.default` = `optionsMarkdown`) — this flake's own option reference,
  generated from all nixtache modules via `nixosOptionsDoc`. Built into the
  `nixtache-options` CI artifact.
- `checks.<system>` — pure-eval test suites (`runner`, `deploy-target`,
  `ab-image`, `mkDocs`, `ab-existing`, `ab-contract`, `auto-update`); built
  by every `nix flake check`.
- `vmTests.x86_64-linux` — KVM-only VM suites (18 of them); **not** run by
  `nix flake check` — run explicitly on a KVM host.
  Testing strategy: [`doc/technical_details/testing.md`](doc/technical_details/testing.md).
- `nixosConfigurations.abtest-remote` — dogfood fixture for
  `tests/ab-deploy.nix`; **not** for real deployment.

## Documentation layers

| Layer | Audience | Content |
|---|---|---|
| [`doc/user_guide/`](doc/user_guide/) | consumers | quickstart, deploy, auto-update, secrets, docs generation, migration — each linking the relevant openspec specs |
| [`doc/technical_details/`](doc/technical_details/) | contributors | architecture, module→CI wiring, sandboxing, workflow mechanics, testing |
| [`openspec/specs/`](openspec/specs/) | everyone (requirements) | the canonical, maintained spec corpus (capabilities: `direct-deploy`, `deploy-user`, `docs`) |
| [`doc/archive/`](doc/archive/) | archaeologists | frozen legacy spec corpus + drafts (superseded / unimplemented), with a freeze note |

## Quickstart pointer

```nix
inputs.nixtache.url = "git+ssh://forgejo@code.zinzaguras.ru/nixops/nixtache.git";
```

Then import `nixtache.nixosModules.runner`, feed it options + secret paths,
and replace your workflows with thin wrappers — the full walkthrough is
[`doc/user_guide/quickstart.md`](doc/user_guide/quickstart.md). Reference
consumer: `codemaster/nixos-configuration`.

## Commands

```bash
nix flake check --show-trace --all-systems   # validate (builds checks.*)
nix build .#optionsMarkdown && cat ./result  # this flake's option reference
nix build .#checks.x86_64-linux.runner && cat ./result   # one suite's report
nix build .#vmTests.x86_64-linux.<suite>     # KVM host only
```

Contributor notes (style, testing rules, openspec workflow):
[`AGENTS.md`](AGENTS.md). Repository-infrastructure constraints (git object
format) are documented in the workspace-level `AGENTS.md` one directory above
this repo.

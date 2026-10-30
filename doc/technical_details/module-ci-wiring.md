# Module → CI wiring

How values declared on the runner host (module options) reach CI jobs running
on it. The runner host is configured by the consumer; the workflows/actions
run on it as jobs. Deployment-specific values (SSH user, bot identity) are NOT
hardcoded in YAML — the module exports them into every job via act_runner's
**`runner.envs`** (a mode-agnostic config key — applies to `host` jobs too,
not just docker), and the bot SSH keys via systemd **`LoadCredential`**:

| module option | job env / credential | used by |
|---|---|---|
| `flakeSshCreds.user` | `NIXTACHE_FLAKE_GIT_USER` + `flake_ssh_{private,public}` LoadCredential | `ssh-setup` (creds: flake) → fetch private flake inputs (`nix flake check`, `nix flake update`, `docs.yml` builds) |
| `updateSshCreds.user` | `NIXTACHE_UPDATE_GIT_USER` + `update_ssh_{private,public}` LoadCredential | `ssh-setup` (creds: update) + `update-flake.yml` guard probe, push URL + commit signing |
| `bot.name` / `bot.email` | `NIXTACHE_BOT_NAME` / `NIXTACHE_BOT_EMAIL` | `update-flake.yml` commit author |
| `gitHost.hostNames[0]` | `NIXTACHE_GIT_SSH_HOST` | push host for `update-flake.yml` guard/push and first entry of the derived `ssh-setup` host list (mechanics: [workflow-mechanics.md](workflow-mechanics.md)); `GITHUB_SERVER_URL` is HTTP-only — its port is the HTTP port, not SSH |
| `gitHost` + `extraKnownHosts` | container known_hosts | must cover **every** hostname nix contacts over SSH: workflows derive the `ssh-setup` host list from `NIXTACHE_GIT_SSH_HOST` plus the `ssh://`/`git+ssh://` hosts in the caller's `flake.lock`, and a derived host without a matching known-host key fails verification |
| `deploy.targets` | `NIXTACHE_DEPLOY_TARGETS` (JSON, secret paths stripped to `hasKey` bools) + `deploy_ssh_<name>[.pub]` LoadCredential | `deploy-target` action → pairs configs and targets by attribute name |
| `deploy.ab.signingKeyFile` | `sysupdate_signing_key` LoadCredential | `deploy-target` action and host `nixtache-ab-gc.service` import the private key from `$CREDENTIALS_DIRECTORY` when signing/regenerating `SHA256SUMS.gpg` |
| `enableSandbox` | `HAS_SANDBOX_CAP` (mirrors the option; build steps do not consume it — see [sandboxing.md](sandboxing.md)) | — (build steps use `SANDBOX_OK`) |

Mechanics, file by file:

- `modules/runner/instances.nix` aggregates all env keys into each
  `forgejo-runner-<name>` service's `settings.runner.envs` (including the
  `_extraRunnerEnvs` internal aggregator that `deploy.nix` and `ab.nix` feed).
- `modules/runner/ssh.nix` bind-mounts the flake/update key pairs into the
  container at `/var/secrets/runner/{flake,update}_ssh_key[.pub]` and wires
  them as per-service `LoadCredential` — only when the corresponding creds
  option is non-null.
- `modules/runner/deploy.nix` does the same for per-target deploy keys at
  `/var/secrets/runner/deploy/<name>/id_ed25519[.pub]`.
- `modules/runner/ab.nix` conditionally adds `sysupdate_signing_key` to every
  in-container `forgejo-runner-<name>` service and to the host
  `nixtache-ab-gc.service`. The deploy action and host GC read that credential,
  never the configured source path. A configured but unreadable source fails
  unit setup; `signingKeyFile = null` supplies no credential and host GC removes
  stale detached signatures. See the
  [runner requirements](../../openspec/specs/runner/spec.md).

## Transport user vs bot account

`flakeSshCreds.user` / `updateSshCreds.user` are the git SSH **transport**
user (the server's `RUN_USER`, e.g. `forgejo`/`git`) — not the bot account.
The two credential bundles are **independent**: `flakeSshCreds` gates
private-input fetch, `updateSshCreds` gates update-flake push. Typically the
consumer points both at the same key files. If `updateSshCreds = null`,
`NIXTACHE_UPDATE_GIT_USER` is empty and `update-flake.yml` **self-disables**
(a guard step no-ops the job with a warning). When it is set, the guard
instead **validates** the credential: `git ls-remote` over the push URL proves
the key authenticates and can read the caller repo, and a broken key fails the
job at the guard — not at the final push (write permission itself cannot be
probed without pushing). update-flake wires **both** bundles into one SSH
config (`creds: "flake update"` — fetch with `flake`, push/sign with
`update`); requirements:
[`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md).
The bot's commit identity is separate (`bot.*`).

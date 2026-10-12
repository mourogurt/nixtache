# Module → CI wiring

How values declared on the runner host (module options) reach CI jobs running
on it. The runner host is configured by the consumer; the workflows/actions
run on it as jobs. Deployment-specific values (SSH user, bot identity) are NOT
hardcoded in YAML — the module exports them into every job via act_runner's
**`runner.envs`** (a mode-agnostic config key — applies to `host` jobs too,
not just docker), and the bot SSH keys via systemd **`LoadCredential`**:

| module option | job env / credential | used by |
|---|---|---|
| `flakeSshCreds.user` | `NIXTACHE_FLAKE_GIT_USER` + `flake_ssh_{private,public}` LoadCredential | `ssh-setup` (creds: flake) → fetch private flake inputs (`nix flake check`) |
| `updateSshCreds.user` | `NIXTACHE_UPDATE_GIT_USER` + `update_ssh_{private,public}` LoadCredential | `ssh-setup` (creds: update) + `update-flake.yml` push URL + commit signing |
| `bot.name` / `bot.email` | `NIXTACHE_BOT_NAME` / `NIXTACHE_BOT_EMAIL` | `update-flake.yml` commit author |
| `gitHost.hostNames[0]` | `NIXTACHE_GIT_SSH_HOST` | `update-flake.yml` SSH push host (canonical SSH endpoint; `GITHUB_SERVER_URL` is HTTP-only — its port is the HTTP port, not SSH) |
| `deploy.targets` | `NIXTACHE_DEPLOY_TARGETS` (JSON, secret paths stripped to `hasKey` bools) + `deploy_ssh_<name>[.pub]` LoadCredential | `deploy-target` action → pairs configs and targets by attribute name |
| `enableSandbox` | `HAS_SANDBOX_CAP` (legacy, nothing consumes it — see [sandboxing.md](sandboxing.md)) | — (superseded by the `SANDBOX_OK` runtime probe) |

Mechanics, file by file:

- `modules/runner/instances.nix` aggregates all env keys into each
  `gitea-runner-<name>` service's `settings.runner.envs` (including the
  `_extraRunnerEnvs` internal aggregator that `deploy.nix` and `ab.nix` feed).
- `modules/runner/ssh.nix` bind-mounts the flake/update key pairs into the
  container at `/var/secrets/runner/{flake,update}_ssh_key[.pub]` and wires
  them as per-service `LoadCredential` — only when the corresponding creds
  option is non-null.
- `modules/runner/deploy.nix` does the same for per-target deploy keys at
  `/var/secrets/runner/deploy/<name>/id_ed25519[.pub]`.

## Transport user vs bot account

`flakeSshCreds.user` / `updateSshCreds.user` are the git SSH **transport**
user (the server's `RUN_USER`, e.g. `forgejo`/`git`) — not the bot account.
The two credential bundles are **independent**: `flakeSshCreds` gates
private-input fetch, `updateSshCreds` gates update-flake push. Typically the
consumer points both at the same key files. If `updateSshCreds = null`,
`NIXTACHE_UPDATE_GIT_USER` is empty and `update-flake.yml` **self-disables**
(a guard step no-ops the job with a warning). The bot's commit identity is
separate (`bot.*`).

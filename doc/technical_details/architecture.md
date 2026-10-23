# Architecture

How the pieces fit: the workspace view, the flake's module layout, and the
way sub-modules merge into one container. Consumer-facing wiring (what to put
in your config) lives in [`doc/user_guide/`](../user_guide/); this document
is for contributors.

## Workspace view

```
                    +------------------+
nixos-private ----->|                  |  inputs.secrets   (git+ssh)
(nixosModules.*)    |                  |
                    |  nixos-          |
nixtache ---------->|  configuration   |  inputs.nixtache  (git+ssh)
(nixosModules:      |   laptop/        |   |- nixosModules.runner
runner, deploy-     |   server)        |   |- nixosModules.deploy-target
target, ab-image,   |                  |   |- nixosModules.ab-image
overlay-nix, auto-  |                  |   |- nixosModules.overlay-nix
update, secrets,    |                  |   |- nixosModules.auto-update
workflows, actions) |                  |   |- nixosModules.secrets
                    +------------------+   |- lib.mkDocs (consumer docs)
                           |
                           v  runs on the Forgejo Actions runner
                       (the runner is declared via the nixtache runner
                        module, consumed by the infra machine)
```

Repository-infrastructure constraints (git object format, remotes) are owned
by the workspace-level `AGENTS.md` one level above this repo — not duplicated
here.

## Module layout

### `modules/runner/` — split by responsibility

All contributions merge into one container via `mkMerge`. The public API and
option surface are identical to the former monolith — consumers and
`tests/runner.nix` are unchanged. The NixOS `containers.<name>.config` option
merges every sub-module's contribution into one container evaluation (see
nixpkgs `nixos/modules/virtualisation/nixos-containers.nix` — its `merge`
concatenates all definitions into the inner `eval-config` modules list).

| File | Owns |
|---|---|
| `default.nix` | Orchestrator: imports, container shell, identity options (`enable`, `forgejoUrl`, `containerName`, `package`, limits, `nixSettings`), base nix gc/optimise, host-side `container@<name>` limits. |
| `types.nix` | Shared option types (`knownHostEntry`, `instanceType`, `sshCredsType`, `deployTargetType`, default GitHub known-hosts). |
| `store.nix` | Relocated store: `store.{path,mode,hostBackup}`, custom `nix-daemon` + storage oneshot + socket, `BindPaths`. |
| `cache.nix` | Binary cache: `cache.*`, `secrets.cachePrivateKey`, in-container `nix-serve`, host-side nginx vhost. |
| `ssh.nix` | `flakeSshCreds` / `updateSshCreds`: key bindMounts + per-service `LoadCredential`. |
| `sandbox.nix` | `enableSandbox` / `additionalCapabilities` (sole owner of container caps), forced `nix.settings.sandbox`. |
| `known-hosts.nix` | `gitHost` / `extraKnownHosts`, in-container `services.openssh.knownHosts`. |
| `instances.nix` | `bot.*` + `instances.<name>`, `forgejo-runner` map, all `runner.envs`. |
| `deploy.nix` | `deploy.targets.<name>` map → job env `NIXTACHE_DEPLOY_TARGETS` + per-target key bind-mounts / `LoadCredential` (`deploy_ssh_<name>[.pub]`). |
| `ab.nix` | Runner-side A/B staging (`deploy.ab.*`): central staging dir + HTTPS distribution via the cache vhost, GPG manifest signing, retain-GC. |

### Sibling modules

| Module | Owns |
|---|---|
| `modules/deploy-target/` | Target side of direct deploy: root `nixtache-apply.service` (activate → probe `criticalUnits` → rollback), polkit start-only rule, `nixtache-deploy` group + pointer dir, deploy-user provisioning with the SSH gate, Tier-0 health check, `ab.*` runtime (gating, partition provisioning). |
| `modules/ab-image/` | Build-time A/B image config: repart slots, UKI, sysupdate transfers, `system.image.{id,version}`, boot counting, GPG verify, the slot's lower store DB dump + boot loader ([`lower-store-db.md`](lower-store-db.md)). |
| `modules/overlay-nix/` | Writable OverlayFS `/nix/store` (lower = RO image store, upper = writable) via `local-overlay-store`, so appliance targets can install packages at runtime. |
| `modules/auto-update/` | Unified auto-update replacing `system.autoUpgrade` (asserted): flake + ab-image paths, shared timer, reboot policy. |
| `modules/secrets.nix` | Secrets provider abstraction (`vars` + extensible `providers`). |

Requirements (canonical) live in
[`openspec/specs/`](../../openspec/specs/) — capabilities updated through
openspec changes. The historical stage-by-stage design record is archived
under [`doc/archive/specs/`](../archive/specs/) (frozen; start with
`0001-direct-deploy.md` and the `direct-deploy/` stages).

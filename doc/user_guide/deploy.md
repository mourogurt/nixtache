# Direct deploy (CI → machines)

nixtache ships a systemd-native deploy pipeline: CI builds a closure and
activates it on the machines you declare — no deploy-rs/colmena, no
sudo/doas/run0 on the targets. Requirements (canonical):
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)
(+ the deploy user contract in
[`openspec/specs/deploy-user/spec.md`](../../openspec/specs/deploy-user/spec.md));
historical stage-by-stage design record:
[`doc/archive/specs/`](../archive/specs/); consumer migration guide:
[`migration.md`](migration.md).

## Runner side: the target map

On the runner host, declare one entry per deployable machine; the attribute
name MUST equal the consumer's `nixosConfigurations.<name>` (the
`deploy-target` action pairs configs and targets by that name):

```nix
services.nixtache.runner.deploy.targets.desktop = {
  host = "desktop.example.com";                         # reachable address
  sshPrivateKey = config.sops.secrets.deploy-desktop-key.path;
  sshPublicKey  = config.sops.secrets.deploy-desktop-key-pub.path;
  method = "live";                                      # "live" (default) | "ab-image"
  # sshUser = "nixos-deploy"; sshPort = 22; timeout = 240; tags = [ ... ]; extraOptions = "...";
};
```

The map is serialized (minus secret paths — only a `hasKey` bool per target
ships) into the job env `NIXTACHE_DEPLOY_TARGETS`; the keys are exposed to
jobs via `LoadCredential` (`deploy_ssh_<name>[.pub]`).

## CI side: the reusable workflow

```yaml
# your .forgejo/workflows/deploy.yml
jobs:
  deploy:
    uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main
    secrets: inherit
```

The mode is derived from the branch inside the action (PR → `dry-activate`,
`main` → `switch`). Deploys are serialized per ref (concurrency group
`deploy-<ref>`, never auto-cancelled) and each target honours its `timeout`.

## Target side: `nixosModules.deploy-target`

Import it on **every** deploy target:

```nix
imports = [ nixtache.nixosModules.deploy-target ];

services.nixtache.deploy-target = {
  criticalUnits = [ "amneziawg-wg0.service" "forgejo.service" ];
  deployUser = {
    name = "nixos-deploy";
    authorizedKey = "ssh-ed25519 AAAA...";  # matches the runner's key for this target
  };
};
```

The module provisions a root-owned `nixtache-apply.service` (set profile →
`switch-to-configuration` → probe `criticalUnits` → re-activate the previous
closure on failure), polkit rules authorizing the deploy user to **start**
that one unit, the `nixtache-deploy` group owning the pointer dir, and a
Tier-0 health check gated on `boot-complete.target`.

## Methods: `live` vs `ab-image`

- **`live`** (default): the runner builds the toplevel, pushes the closure
  with `nix copy --to ssh://…`, drops a pointer file and triggers
  `nixtache-apply.service`.
- **`ab-image`**: the target boots A/B appliance images
  (`nixosModules.ab-image` + `deploy-target.ab.*`); the runner builds, signs
  and stages a `sysupdate-package` centrally (`deploy.ab.*` on the runner
  module), and the target's `systemd-sysupdate` writes the inactive slot and
  reboots. The runner host itself self-updates through the idle-gated
  `nixtache-ab-apply` unit.

## Security model

- The deploy user is a **system user** (uid < 1000, invisible on login
  screens) whose key is gated by `nixtache-ssh-gate` — an authorized_keys
  `restrict,command=` prefix allowing exactly the probe, `nix-store --serve`,
  the apply trigger and the A/B triggers; everything else is rejected.
- It may **start** `nixtache-apply.service` (polkit, start-only) and write
  the pointer file (`nixtache-deploy` group). No sudo/doas/run0 anywhere.
- It is added to `nix.settings.trusted-users` **unconditionally**: `nix copy
  --to ssh://…` pushes locally-built unsigned closures, which the daemon only
  imports for trusted users (nix.conf(5)) — a protocol requirement of the
  live path, not an optional privilege.

## Auto-update

The `auto-update` module replaces `system.autoUpgrade` and shares this
pipeline — see [`auto-update.md`](auto-update.md) and
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)
(historical stage spec:
[`doc/archive/specs/direct-deploy/09-auto-update.md`](../archive/specs/direct-deploy/09-auto-update.md)).

# Direct deploy (CI → machines)

nixtache ships a systemd-native deploy pipeline: CI builds a closure and
activates it on the machines you declare — no deploy-rs/colmena, no
sudo/doas/run0 on the targets. Requirements (canonical):
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)
(+ the deploy user contract in
[`openspec/specs/deploy-user/spec.md`](../../openspec/specs/deploy-user/spec.md));
historical stage-by-stage design record:
[`doc/archive/specs/`](../archive/specs/); the OTA (A/B image) route has its
own guide: [`ota.md`](ota.md).

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
  # minFreeBytes = 5 * 1024**3;                          # pre-copy disk preset; 0 disables the check
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

### Disk-space guard

| Option | Default | Meaning |
|---|---|---|
| `services.nixtache.deploy-target.minFreeBytes` | `5 * 1024 * 1024 * 1024` (5 GiB) | Minimum free bytes on the store filesystem for `nixtache-apply.service` to start an activation. Below the threshold the unit refuses **before** touching the system profile: it consumes the pointer file, logs the deficit with a garbage-collection hint, and exits non-zero — the running generation stays active, no rollback runs (nothing was mutated). `0` disables the guard. |

This is activation headroom, not retention policy — what to collect stays a
consumer-side concern. Canonical requirement:
[`openspec/specs/direct-deploy/spec.md](../../openspec/specs/direct-deploy/spec.md)
("Apply-unit low-disk guard"); the runner-side pre-copy check is described in
[Pre-flight disk-space check](#pre-flight-disk-space-check) below.


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

## Pre-flight disk-space check

Before any closure data moves, the action checks each `live` target's free
store space against its preset — the deploy-map option
`services.nixtache.runner.deploy.targets.<name>.minFreeBytes` (default
5 GiB; `0` disables the check for that target entirely). The free space
itself is queried through the gated SSH channel — the exact, read-only
command `df -B1 --output=avail /nix/store` is whitelisted by
`nixtache-ssh-gate`. Two stages:

1. **Pre-build** (fast refuse): free space below the preset fails the
   target immediately — nearly-full machines are skipped in seconds,
   without a build.
2. **Post-build** (sized check): the deployment need is estimated as the
   narSize sum of the closure paths **missing** on the target (remote store
   inventory through the serve channel) × 1.1 **+ preset**; if the
   inventory query fails, the conservative fallback is the full closure
   size × 1.1 + preset.

A target short on space records `::error::<name>: target <host> low on disk
(<avail> B free, <need> B needed)` — no `nix copy` runs and the apply unit
is not triggered for it — while the loop continues with the remaining
targets; the job fails at the end if any target errored. A **rejected**
query means protocol drift (the target's gate predates the action) and is a
*transition* condition, not a failure: the target is skipped with a
per-target `::warning::` naming the `sshGate = "restrict"` escape hatch,
and drift alone never fails the job. The target-side activation guard
(`deploy-target.minFreeBytes`) is the
second line of defence — see [Disk-space guard](#disk-space-guard) above;
keep the runner-side preset ≥ the target-side guard (the runner cannot read
the target's module config).

All action SSH invocations (probe, copy, triggers) pin
`UserKnownHostsFile` to `$PWD/.deploy-known-hosts` instead of relying on
the job's `HOME` (which runner job environments do not have): no `/.ssh`
warnings, and target host keys verify against a stable per-job file.

Canonical requirements:
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)
("Pre-copy target disk-space check", "Deploy SSH does not depend on the job
HOME") and
[`openspec/specs/deploy-user/spec.md`](../../openspec/specs/deploy-user/spec.md)
("Gate allows the disk-space query").

## Security model

- The deploy user is a **system user** (uid < 1000, invisible on login
  screens) whose key is gated by `nixtache-ssh-gate` — an authorized_keys
  `restrict,command=` prefix allowing exactly the probe, `nix-store --serve`,
  the apply trigger, the A/B triggers and the read-only free-space query
  (`df -B1 --output=avail /nix/store`, exact match); everything else is
  rejected.
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


## Protocol-drift rollout order

When a nixtache release extends the gated SSH protocol (new whitelisted
command — e.g. the disk-space query), a **new action against an old gate**
is a transition condition, not a failure: the affected target is skipped
with a per-target `::warning::` and the job stays green. Roll out
**module first, action second**:

1. Bump nixtache and deploy every target once with the *current* action —
   the new generation carries the extended gate.
2. From the next run, the new action finds the command whitelisted
   everywhere.

If a target lags (still on a pre-change generation), temporarily set
`services.nixtache.deploy-target.deployUser.sshGate = "restrict"` on it and
revert to `"gate"` once it catches up — the same protocol-drift escape
hatch as above.

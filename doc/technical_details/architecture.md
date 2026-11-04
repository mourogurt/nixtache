# Architecture

How the pieces fit: consumer integration, the flake's module layout, and the
way runner sub-modules merge into each declared container. Consumer-facing
wiring (what to put in your config) lives in
[`doc/user_guide/`](../user_guide/); this document is for contributors.

## Consumer integration

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
update, workflows,  |                  |   |- nixosModules.auto-update
actions)            |                  |   |- lib.mkDocs (consumer docs)
                    +------------------+
                           |
                           v  runs on the Forgejo Actions runner
                       (the runner is declared via the nixtache runner
                        module, consumed by the infra machine)
```

## Module layout

### `modules/runner/` — split by responsibility

All contributions for a declaration merge into its container via `mkMerge`.
The NixOS `containers.<name>.config` option merges every sub-module's
contribution into that container evaluation (see nixpkgs
`nixos/modules/virtualisation/nixos-containers.nix` — its `merge` concatenates
all definitions into the inner `eval-config` modules list).

| File | Owns |
|---|---|
| `default.nix` | Orchestrator: imports, shared defaults, named `containers` declarations normalized with the singleton `containerName`/`store`/`instances` compatibility path, container shells and host-side `container@<name>` limits. |
| `types.nix` | Shared option types (`knownHostEntry`, `instanceType`, `sshCredsType`, `deployTargetType`, runner container/store declarations, default GitHub known-hosts). |
| `store.nix` | Per-declaration relocated store: `store.{path,mode,hostBackup,parent}`, custom daemon + socket + `BindPaths`; additive `nix-daemon-storage` in clone mode or `nix-daemon-overlay-mount` over the selected frozen parent root in overlay mode. |
| `cache.nix` | Binary cache: `cache.*`, `secrets.cachePrivateKey`, in-container `nix-serve`, host-side nginx vhost with an edge cache ([availability machinery](binary-cache-availability.md)). |
| `ssh.nix` | `flakeSshCreds` / `updateSshCreds`: key bindMounts + per-service `LoadCredential`. |
| `sandbox.nix` | `enableSandbox` / `additionalCapabilities` (sole owner of container caps), forced `nix.settings.sandbox`. |
| `known-hosts.nix` | `gitHost` / `extraKnownHosts`, in-container `services.openssh.knownHosts`. |
| `instances.nix` | `bot.*` + `instances.<name>`, `forgejo-runner` map, all `runner.envs`. |
| `deploy.nix` | `deploy.targets.<name>` map → job env `NIXTACHE_DEPLOY_TARGETS` + per-target key bind-mounts / `LoadCredential` (`deploy_ssh_<name>[.pub]`). |
| `ab.nix` | Runner-side A/B staging (`deploy.ab.*`): central staging dir + HTTPS distribution via the cache vhost, GPG manifest signing, retain-GC. |

### Runner custom-daemon builder identities

For a relocated store, `store.nix` declares the `nixtache-runner-bld` group
(GID `32000`) and static builder users with UIDs from `32001` upward. The
default is 32 users (`32001`–`32032`); larger numeric `max-jobs` values extend
the set, capped at UID `61183`. Host evaluation rejects overlap with
statically declared host user UIDs or group GIDs.

Only `nix-daemon-custom` receives `build-users-group = nixtache-runner-bld`
and `auto-allocate-uids = false` in its `NIX_CONFIG`. The global container
`nix.conf`, system daemon and clone seeder keep their existing builder
configuration. Because host and container processes share numeric UIDs, these
separate identities are what prevent one daemon's UID-wide builder cleanup
from targeting the other daemon's processes. Canonical requirements:
[`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md).

### Sibling modules

| Module | Owns |
|---|---|
| `modules/deploy-target/` | Target side of direct deploy: root `nixtache-apply.service` (activate → probe `criticalUnits` → rollback), polkit start-only rule, `nixtache-deploy` group + pointer dir, deploy-user provisioning with the SSH gate, Tier-0 health check, `ab.*` runtime (gating, partition provisioning). |
| `modules/ab-image/` | Build-time A/B image config: repart slots, UKI, sysupdate transfers, `system.image.{id,version}`, boot counting, GPG verify, the slot's lower store DB dump + boot loader ([`lower-store-db.md`](lower-store-db.md)), and the overlay-enabled target topology descriptor. |
| `modules/overlay-nix/` | Writable OverlayFS `/nix/store` via `local-overlay-store`; `topology.nix`/`physical.nix` derive logical and frozen/runtime graphs from runner declarations, `planner.py` validates target descriptors and operations, `preparation.nix` owns private target construction/publication, `selection.nix` and `migration.nix` activate or restore one physical-slot generation, and `systemd.nix` orders consumers behind readiness. |
| `modules/auto-update/` | Unified auto-update replacing `system.autoUpgrade` (asserted): flake + ab-image paths, poll timer, target preparation, and deferred-reboot source refresh in window mode. |

### Lower installation versus upper readiness

The A/B image and overlay modules own different steps of an update:

- `ab-image`/sysupdate installs the inactive lower partition, UKI, lower dump
  and, when overlay is enabled, the target topology descriptor. Completing
  that write does not make the upper chain ready.
- `overlay-nix` validates the descriptor and prepares only the inactive
  physical slot's target graph. Wipe creates empty upper-owned state;
  reconcile clones the current active generation and repairs the copy in a
  private namespace. Readiness binds the lower checksum, descriptor and final
  logical/physical graph only after the complete target validates.
- `nixtache-ab-update` and the auto-update poll invoke preparation after every
  confirmed lower installation and before reboot. Preparation is rerunnable,
  so v2 followed by v3 without an intermediate reboot publishes and selects
  the exact ready v3 generation. A same-version rewrite is likewise detected
  by a changed lower-dump checksum.
- The persistent deferred-reboot path fingerprints the complete active upper
  generation. Changes during the window force another target preparation:
  reconcile freezes the latest parent runtime continuations before children
  rebase, while wipe keeps target state clean. A running child never receives
  a live lower refresh; parent writes cross only when it restarts into the
  rebased generation.
- An entirely ephemeral chain returns a successful no-persistent-metaslot
  result, then resets all descendants and loads exactly the new lower dump at
  boot. The current deferred-window fingerprint restriction is documented in
  [`auto-update.md`](../user_guide/auto-update.md#ab-upper-readiness-and-deferred-reboots).
- Early boot selects a ready generation from the mounted lower's GPT
  `PARTUUID`, with descriptor, graph and lower-dump checksum validation. Upper
  consumers and `boot-complete.target` require that selection. Recovery of an
  unprepared target runs before consumers start; failure does not bless the
  boot.
- Automatic or manual rollback selects the previous lower and its complete
  preserved logical and physical upper graph. It never performs a reverse
  wipe, clone, metadata merge or reconcile.

The detailed lifecycle has one owner:
[`doc/user_guide/overlay-nix.md`](../user_guide/overlay-nix.md). Canonical
contracts: [`ab-ota`](../../openspec/specs/ab-ota/spec.md),
[`overlay-nix`](../../openspec/specs/overlay-nix/spec.md), and
[`runner`](../../openspec/specs/runner/spec.md) for dependent runner overlays.

Requirements (canonical) live in
[`openspec/specs/`](../../openspec/specs/) — capabilities updated through
openspec changes. The historical stage-by-stage design record is archived
under [`doc/archive/specs/`](../archive/specs/) (frozen; start with
`0001-direct-deploy.md` and the `direct-deploy/` stages).

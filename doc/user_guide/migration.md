# Consumer migration: direct deploy + auto-update

A practical guide for repositories consuming nixtache: adopting the deploy
feature, moving from `system.autoUpgrade` to the unified auto-update module,
and the BREAKING changes of the `finalize-direct-deploy` change. Requirements
(canonical):
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md)
+ [`openspec/specs/deploy-user/spec.md`](../../openspec/specs/deploy-user/spec.md);
historical design record:
[`doc/archive/specs/`](../archive/specs/).

## 1. Adopting the deploy feature (from scratch)

### 1.1 Runner host: the target map + keys

In the config of the machine running `services.nixtache.runner`, add the map —
one entry per `nixosConfigurations.<name>` this runner may deploy to:

```nix
{ config, ... }: {
  sops.secrets.deploy-key-desktop = { sopsFile = ../../secrets/deploy-keys/desktop.ed25519; format = "binary"; };

  services.nixtache.runner.deploy.targets.desktop = {
    host          = "10.13.37.3";              # LAN/VPN address of the target
    sshUser       = "nixos-deploy";            # default
    sshPrivateKey = config.sops.secrets.deploy-key-desktop.path;
    # method = "ab-image";                     # only for A/B (OTA) targets
    # timeout = 240;                            # minutes per target (default)
  };
}
```

The map is serialized into the job env `NIXTACHE_DEPLOY_TARGETS` (without
secret paths); the keys go into `LoadCredential deploy_ssh_<name>`.

### 1.2 Target: the receiving module

In the config of **every** target machine:

```nix
{ ... }: {
  imports = [ inputs.nixtache.nixosModules.deploy-target ];

  services.nixtache.deploy-target = {
    criticalUnits = [ "wireguard-awg0.service" ];  # what counts as "machine alive"
    healthCheckTimeout = 300;                       # seconds (default)
    deployUser = {
      authorizedKey = "ssh-ed25519 AAAA…";           # pair of the runner's deploy key
      # name = "nixos-deploy";                       # default
      # sshGate = "gate";                            # default: restrict,command=<gate>
    };
  };
}
```

The module provisions: the system deploy user (invisible in SDDM), the
root-owned `nixtache-apply.service` (switch → probe `criticalUnits` →
rollback), a polkit rule for `start` only, a Tier-0 health check, and the SSH
gate.

### 1.3 Workflow wrapper in the consumer

`.forgejo/workflows/deploy.yml`:

```yaml
on: [ push, pull_request ]
jobs:
  deploy:
    uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main
```

The mode follows the branch: PR → `dry-activate`, `main` → `switch`. An
unreachable host is skipped with a warning — CI does not fail.

## 2. Moving from `system.autoUpgrade` to auto-update

```nix
# BEFORE                          # AFTER
system.autoUpgrade = {            services.nixtache.auto-update = {
  enable = true;                    enable = true;
  flake = "git+ssh://…/nixos-configuration";
  dates = "daily";                  flake.url = "git+ssh://…/nixos-configuration";
};                                  dates = "daily";
                                   rebootPolicy = "if-needed";
                                 };
```

Enabling both together is an eval error. The flake path builds the toplevel
and activates it through `nixtache-apply.service` (never `nixos-rebuild`);
for A/B targets set `method = "ab-image"` (or leave `auto`). It requires
`nixosModules.deploy-target` to be imported. Full option reference:
[`auto-update.md`](auto-update.md).

## 3. BREAKING changes (the `finalize-direct-deploy` change)

| Change | Migration |
|---|---|
| Option `deployUser.nixTrust` **removed** | Delete it from your config. The deploy user lands in `nix.settings.trusted-users` **unconditionally** — a protocol requirement of `nix copy --to ssh://` (the daemon imports locally-built unsigned closures only for trusted users, nix.conf(5)). For custom trust, set `nix.settings.trusted-users` yourself |
| Deploy user is now a **system user** (`isSystemUser`, uid < 1000) | Nothing to do: the account disappears from login screens (SDDM/Plasma). If things look odd, remove the old normal user (`sudo userdel nixos-deploy`) before the first deploy |
| The deploy key's SSH session is **gated** (`restrict,command=`) | The default (`sshGate = "gate"`) passes only the deploy-protocol commands. On protocol drift (new action ↔ old module on targets), temporarily set `sshGate = "restrict"` and revert after a synchronized upgrade |
| `systemd-sysupdate-reboot.service` instead of plain | Remote A/B targets reboot after the slot is written (that IS the activation). If unscheduled reboots are unwanted, don't trigger it manually; the auto channel respects `rebootPolicy` |
| `onSizeMismatch = "error"` masks sysupdate (runtime) | Manual resolution: fix `slotSize` (or `wipe`), rebuild, `systemctl unmask --runtime systemd-sysupdate.service`, restart the provision unit |

## 4. Upgrade order

1. Bump `inputs.nixtache` → `nix flake check` of your flake: you'll hit the
   eval errors of the BREAKING items above (first of all `nixTrust`).
2. Apply the §3 table, deploy the runner-host configuration.
3. One deploy per target (or a local `nixos-rebuild switch`) — the module
   provisions the system deploy user and the gate.
4. Smoke test: PR → dry-activate → merge to main → switch; inspect the
   target's `journalctl -u nixtache-apply.service`.

## 5. Two-phase rollout of protocol extensions (the disk-space gate)

The deploy-disk-space-gate change extends the gated SSH protocol with a new
command: the action's pre-copy check issues `df -B1 --output=avail
/nix/store` through the deploy key (see
[`deploy.md`](deploy.md) → "Pre-flight disk-space check"; canonical:
[`openspec/specs/deploy-user/spec.md](../../openspec/specs/deploy-user/spec.md)
"Gate allows the disk-space query"). A **new action against an old gate**
gets the query rejected and **skips that target with a per-target warning**
(the job stays green — drift is a transition condition, not a failure).
Upgrade order:

1. **Module first**: bump nixtache and deploy every target once with the
   *current* action — the new generation carries the extended gate (plus
   the apply-unit `minFreeBytes` guard, which needs no protocol change).
2. **Then the action**: the next run of the new action finds the query
   whitelisted everywhere.

If a target lags (still on a pre-change generation), temporarily set
`services.nixtache.deploy-target.deployUser.sshGate = "restrict"` on it and
revert to `"gate"` once it catches up — the same protocol-drift escape
hatch as §3.

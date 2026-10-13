# Consumer migration: finalize-direct-deploy (frozen)

> **Frozen history.** This is the BREAKING-changes record of the
> `finalize-direct-deploy` change, retired from `doc/user_guide/migration.md`
> when the live guide absorbed its current content (upgrade guidance now
> lives in `deploy.md` → "Protocol-drift rollout order" and
> `auto-update.md`; the canonical requirements are
> [`openspec/specs/`](../specs/)). Kept for consumers crossing this
> boundary from an older nixtache.

## BREAKING changes (the `finalize-direct-deploy` change)

| Change | Migration |
|---|---|
| Option `deployUser.nixTrust` **removed** | Delete it from your config. The deploy user lands in `nix.settings.trusted-users` **unconditionally** — a protocol requirement of `nix copy --to ssh://` (the daemon imports locally-built unsigned closures only for trusted users, nix.conf(5)). For custom trust, set `nix.settings.trusted-users` yourself |
| Deploy user is now a **system user** (`isSystemUser`, uid < 1000) | Nothing to do: the account disappears from login screens (SDDM/Plasma). If things look odd, remove the old normal user (`sudo userdel nixos-deploy`) before the first deploy |
| The deploy key's SSH session is **gated** (`restrict,command=`) | The default (`sshGate = "gate"`) passes only the deploy-protocol commands. On protocol drift (new action ↔ old module on targets), temporarily set `sshGate = "restrict"` and revert after a synchronized upgrade |
| `systemd-sysupdate-reboot.service` instead of plain | Remote A/B targets reboot after the slot is written (that IS the activation). If unscheduled reboots are unwanted, don't trigger it manually; the auto channel respects `rebootPolicy` |
| `onSizeMismatch = "error"` masks sysupdate (runtime) | Manual resolution: fix `slotSize` (or `wipe`), rebuild, `systemctl unmask --runtime systemd-sysupdate.service`, restart the provision unit |

## Upgrade order

1. Bump `inputs.nixtache` → `nix flake check` of your flake: you'll hit the
   eval errors of the BREAKING items above (first of all `nixTrust`).
2. Apply the table above, deploy the runner-host configuration.
3. One deploy per target (or a local `nixos-rebuild switch`) — the module
   provisions the system deploy user and the gate.
4. Smoke test: PR → dry-activate → merge to main → switch; inspect the
   target's `journalctl -u nixtache-apply.service`.

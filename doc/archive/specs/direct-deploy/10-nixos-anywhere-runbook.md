# 10. nixos-anywhere migration runbook (N1/N2)

Manual integration checks for migrating an existing host to the A/B image
layout with `nixos-anywhere` (TEST-SPECS §6). nixtache does not generate the
disko config (spec 08 §1-A) — these steps verify the *result* of the install,
not the tooling.

## N1 — `ab-nixos-anywhere`: kexec → disko → install → boot on A/B

> **Automated variant available.** The full OTA lifecycle (kexec install →
> A/B disko layout → UKI boot → signed v2 sysupdate onto slot B) is now
> covered end-to-end by `checks.x86_64-linux.ab-ota-anywhere-vm` (runNixOSTest,
> KVM). The manual steps below remain the reference for bare-metal runs and
> for verifying things a VM cannot (real firmware, real disks).

1. Install:

   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#server-ab-image \
     --target-host root@server \
     --disko-mode destroy,format,mount
   ```

2. Post-install assertions (run on the installed host):

   ```bash
   # GPT labels: populated slot A + reserved slot B
   sgdisk -p /dev/nvme0n1 | grep -E 'nix-store_1|_empty'

   # /nix/store is a read-only compressed image mount
   mount | grep /nix/store | grep squashfs   # or erofs, per storeFs

   # the sysupdate timer is up (OTA updates are scheduled)
   systemctl is-active systemd-sysupdate.timer
   ```

   Expected: one `nix-store_1` + one `_empty` partition; `/nix/store` mounted
   from the squashfs/erofs image; timer `active`.

## N2 — `ab-nixos-anywhere-hostkeys`: SSH host key persistence

`nixos-anywhere --copy-host-keys` carries the host's SSH host keys through a
reinstall.

1. Before reinstall, record the fingerprints:

   ```bash
   ssh-keyscan server | ssh-keygen -lf - > hostkeys.before
   ```

2. Reinstall with `--copy-host-keys` (see N1 command), then re-record:

   ```bash
   ssh-keyscan server | ssh-keygen -lf - > hostkeys.after
   diff hostkeys.before hostkeys.after
   ```

   Expected: no diff — every host key fingerprint is identical before and
   after the reinstall.

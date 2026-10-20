# Proposal

## Why

Run 955 of `codemaster/nixos-configuration` (first update-flake run on the
new workflow) still fails to fetch private inputs: `ssh-setup` writes a single
`Host` block for the push host (`NIXTACHE_GIT_SSH_HOST` =
`gitHost.hostNames[0]`, e.g. `zinzaguras.ru`), but `flake.lock` input URLs
point at a different hostname for the same server (e.g.
`code.zinzaguras.ru`). Keys are loaded but never offered for the lock-file
host → `Permission denied (publickey)` at `nix flake update`. The guard probe
passes because it targets the push host, which IS covered.
`nix-check.yml` only works because it hardcodes
`git-host: code.zinzaguras.ru` — a vendor-specific value masking the same
bug class.

## What Changes

- `ssh-setup`'s `git-host` input accepts a **space-separated host list** and
  writes one `Host` block per entry (each with its own `HostName` and optional
  `port`). Single-host invocations keep byte-identical output.
- `update-flake.yml` derives the host list at runtime: the push host
  (`NIXTACHE_GIT_SSH_HOST`, first) plus every SSH host found in
  `flake.lock` (`locked.url` entries with `ssh://`/`git+ssh://` scheme) —
  data-driven, no hardcoded consumer hostnames.
- The guard probe and push URL keep using the push host (first of the list).
- `nix-check.yml` switches from the hardcoded
  `git-host: code.zinzaguras.ru` to the same lock-derived host list —
  removes the last vendor-specific hostname from reusable workflows.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ci-workflows`: add a requirement that the generated SSH config covers all
  hosts the job will contact (push host + flake.lock input hosts).

## Impact

- `.forgejo/actions/ssh-setup/action.yml`: multi-host `git-host`.
- `.forgejo/workflows/update-flake.yml`: githost step becomes a multi-host
  derivation (jq over `flake.lock`).
- `.forgejo/workflows/nix-check.yml`: hardcoded host replaced by the same
  derivation.
- Docs: `doc/technical_details/workflow-mechanics.md` (mechanics rows),
  `doc/technical_details/module-ci-wiring.md` (host derivation note).
- No module options change; consumers need `gitHost.hostNames` to include
  every hostname nix will contact (already required today for known_hosts).

# Proposal

## Why

Run 907 of `codemaster/nixos-configuration` showed `update-flake.yml` green
while `nix flake update` failed to fetch the private `nixops/nixtache` input
(`Permission denied (publickey)`): the workflow never sets up fetch
credentials, and nix downgrades fetch failures to warnings ("using expired
cached ref"), exiting 0. Separately, the update-flake guard only checks that
`NIXTACHE_UPDATE_GIT_USER` is non-empty — a configured-but-broken push key is
discovered at the final `git push`, after a full update+validate+rebuild run.

## What Changes

- **Guard validates the push credential, not just its presence.** After SSH
  setup, the guard probes authentication + repo access with
  `git ls-remote` over the push URL (`update` key). Configured-but-invalid →
  fail fast at the guard with a clear error. `updateSshCreds = null` keeps the
  current no-op-with-warning semantics.
- **update-flake sets up fetch credentials.** The `flake` SSH bundle (same as
  `nix-check.yml`) is configured alongside `update`, so `nix flake update` can
  fetch private inputs. `ssh-setup` gains multi-bundle support (one SSH config,
  one `IdentityFile` per bundle).
- **Fetch failures fail the update step.** "Update Flakes Inputs" fails when
  the captured log contains nix fetch errors, even when nix exits 0 via the
  cache fallback.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ci-workflows`: add requirements for guard credential validation, fetch-cred
  setup in update-flake, and hard failure on swallowed fetch errors.

## Impact

- `.forgejo/workflows/update-flake.yml`: step reorder (ssh-setup before
  guard), guard probe, fetch-error detection in the update step.
- `.forgejo/actions/ssh-setup/action.yml`: `creds` accepts a space-separated
  list; single config with one `IdentityFile` per bundle; `key-path` output
  stays the signing (update) key when present.
- Docs: `doc/technical_details/workflow-mechanics.md`,
  `doc/technical_details/module-ci-wiring.md` (guard semantics change).
- No NixOS module option changes; consumers need no migration (runners with
  only `updateSshCreds` set keep working for public-input flakes; private
  inputs additionally need `flakeSshCreds`).

# Spec Delta

## ADDED Requirements

### Requirement: docs sets up fetch credentials for private inputs

`docs.yml` SHALL configure the `flake` SSH credential bundle before invoking `generate-docs`, so documentation builds can fetch private flake inputs of the caller repository.

#### Scenario: uncached private input revision fetches successfully

- **WHEN** the caller flake locks a private `git+ssh` input at a revision absent from the runner cache and the runner provides `flakeSshCreds`
- **THEN** SSH setup completes before `generate-docs`, and the docs build fetches that revision without `Permission denied (publickey)` errors

#### Scenario: missing flake credentials degrade gracefully for public inputs

- **WHEN** the caller flake has only public inputs and the runner does not provide `flakeSshCreds`
- **THEN** the setup step warns and skips the flake bundle, and documentation generation proceeds

## MODIFIED Requirements

### Requirement: SSH config covers every host the job contacts

Reusable workflows SHALL pass `ssh-setup` the complete set of hostnames the
job contacts over SSH — the push host (`NIXTACHE_GIT_SSH_HOST`) plus every
SSH host referenced by the caller's `flake.lock` input URLs — so the
credential keys are offered on every connection nix makes.

#### Scenario: private input on an alias host fetches

- **WHEN** the push host is `zinzaguras.ru` but `flake.lock` input URLs use
  `ssh://forgejo@code.zinzaguras.ru/…`
- **THEN** the generated SSH config has `Host` blocks for both hostnames, and
  `nix flake update` offers the credential key when connecting to
  `code.zinzaguras.ru`

#### Scenario: docs build fetches a private input on an alias host

- **WHEN** `docs.yml` builds a caller flake whose private input URL uses an SSH hostname different from `NIXTACHE_GIT_SSH_HOST`
- **THEN** the generated SSH config covers both hostnames and `generate-docs` offers the flake credential when fetching the input

#### Scenario: host list is derived from flake.lock, not hardcoded

- **WHEN** `update-flake.yml`, `nix-check.yml`, or `docs.yml` runs
- **THEN** the host list passed to `ssh-setup` is the push host (from
  `NIXTACHE_GIT_SSH_HOST`) plus the SSH hosts extracted from the checked-out
  `flake.lock`, deduplicated — no consumer hostname is hardcoded in the
  workflow files

#### Scenario: guard still probes the push host

- **WHEN** `update-flake.yml` validates the update credential
- **THEN** the `ls-remote` probe targets the push URL on
  `NIXTACHE_GIT_SSH_HOST`, regardless of how many hosts the SSH config covers

# Spec Delta

## ADDED Requirements

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

#### Scenario: host list is derived from flake.lock, not hardcoded

- **WHEN** `update-flake.yml` or `nix-check.yml` runs
- **THEN** the host list passed to `ssh-setup` is the push host (from
  `NIXTACHE_GIT_SSH_HOST`) plus the SSH hosts extracted from the checked-out
  `flake.lock`, deduplicated — no consumer hostname is hardcoded in the
  workflow files

#### Scenario: guard still probes the push host

- **WHEN** `update-flake.yml` validates the update credential
- **THEN** the `ls-remote` probe targets the push URL on
  `NIXTACHE_GIT_SSH_HOST`, regardless of how many hosts the SSH config covers

### Requirement: ssh-setup git-host accepts a host list

`ssh-setup`'s `git-host` input SHALL accept a space-separated host list,
writing one `Host` block per host; a `host:port` token maps to `HostName` +
`Port` in that host's own block.

#### Scenario: single-host callers are unaffected

- **WHEN** `ssh-setup` is invoked with one host (e.g. `deploy`-side usage)
- **THEN** the generated SSH config is byte-identical to the single-host form
  that predates the host list

#### Scenario: per-host port stays per-host

- **WHEN** the host list is `alpha.example beta.example:2222`
- **THEN** the generated config has a `Port 2222` line only inside
  `beta.example`'s block

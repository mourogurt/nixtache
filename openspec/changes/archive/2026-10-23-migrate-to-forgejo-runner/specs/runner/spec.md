# runner Delta

## ADDED Requirements

### Requirement: Runner registration via uuid and token pair

The module SHALL wire each enabled `services.nixtache.runner.instances.<name>`
to an instance of the in-container `services.forgejo-runner` module whose
connection `default` carries `url = services.nixtache.runner.forgejoUrl`,
`uuid = instances.<name>.uuid`, and the runner token read from a read-only
bind mount of `instances.<name>.tokenFile` via the module's
`secrets.server.connections.default.token_url` mechanism. Each instance
SHALL be its own registration (own uuid and own token).

#### Scenario: Token file holds the bare token

- **WHEN** a consumer prepares an instance's token file
- **THEN** it contains the bare runner token — no `TOKEN=` prefix, no
  environment-file syntax: runners no longer self-register, the uuid +
  token pair is obtained from Forgejo when the registration is created

#### Scenario: Default instance is fully wired

- **WHEN** one enabled instance `default` is configured with `uuid` and
  `tokenFile`
- **THEN** the container config contains
  `services.forgejo-runner.instances.default` with
  `settings.server.connections.default.url = forgejoUrl` and
  `settings.server.connections.default.uuid` equal to the configured uuid,
  and `secrets.server.connections.default.token_url` pointing at the
  bind-mounted token path `/var/secrets/runner/default/token`
- **AND** that bind mount's hostPath is the configured `tokenFile`, read-only

#### Scenario: Two instances are independent registrations

- **WHEN** instances `default` and `test` are both enabled
- **THEN** each gets its own uuid in its own connection map and its own
  read-only token bind mount `runner-token-<name>`

### Requirement: Instance options track the forgejo-runner module

`instances.<name>.labels` SHALL land in `settings.runner.labels` of the
corresponding in-container instance, keeping the default
`[ "nixos:host" ]`. The module SHALL NOT re-expose a runner-name option:
runners no longer self-report their name to Forgejo (the name is fixed when
the registration is created), so `instances.<name>.name` SHALL fail
evaluation.

#### Scenario: Labels reach the new settings location

- **WHEN** an instance sets `labels = [ "nixos:test" ]`
- **THEN** the in-container instance's `settings.runner.labels` is
  `[ "nixos:test" ]`

#### Scenario: Runner name is not settable

- **WHEN** a consumer sets `instances.default.name`
- **THEN** evaluation fails (the option no longer exists)

### Requirement: Container nix daemon trusts the runner service users

The in-container `nix.settings.trusted-users` SHALL include
`forgejo-runner-<name>` — the NSS-visible name of the dynamic user of each
`forgejo-runner-<name>.service` — for every enabled instance, and SHALL NOT
reference the removed `gitea-runner` account. Host-mode jobs therefore stay
trusted nix clients: they may use the configured substituters and copy
closures out of the store (direct deploy).

#### Scenario: Trusted users track the instances

- **WHEN** instances `default` and `test` are enabled
- **THEN** the container's `nix.settings.trusted-users` contains
  `forgejo-runner-default` and `forgejo-runner-test`, and does not contain
  `gitea-runner`

#### Scenario: Trusted users stay correct with no instances beyond default

- **WHEN** only the `default` instance is enabled
- **THEN** `trusted-users` contains `forgejo-runner-default` exactly for
  that instance and nothing else beyond the module's static entries

### Requirement: Registration migration documentation

The user guide SHALL document the one-time migration from the
self-registration model to the uuid + token model: extracting `uuid` and
`token` from the `.runner` file of a previously registered runner
(`/var/lib/gitea-runner/<name>/.runner` inside the still-running old
container), the token-file format change, and creating a fresh runner
registration in Forgejo.

#### Scenario: Consumer migrates an existing runner

- **WHEN** a consumer with a running old-model runner upgrades nixtache
- **THEN** the user guide explains how to read the old `.runner` file and
  where to put each value, without requiring source-code reading

#### Scenario: Consumer registers a new runner

- **WHEN** a consumer has no old registration to reuse
- **THEN** the user guide explains how to create a runner registration in
  Forgejo and obtain the uuid + token pair

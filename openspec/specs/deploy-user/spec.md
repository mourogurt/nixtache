# deploy-user Specification

## Purpose

Provisioning of the deploy user on the target machine (receiving `deploy-target` module): a dedicated system account used only for SSH activation, hidden from graphical login screens and granted no additional privileges.

## Requirements

### Requirement: Deploy user is a system account

With `deployUser.autoProvision = true`, the module MUST create the user as a **system account**: `isSystemUser = true`, a system-range uid (< 1000), no `isNormalUser`, and no home directory in `/home`. The user MUST NOT appear in graphical login screens (SDDM/Plasma, etc.) while retaining key-based SSH login and activation commands (`nix copy`, pointer writes, polkit-authorized `systemctl start`).

#### Scenario: Deploy user is not visible in SDDM

- **WHEN** SDDM (Plasma) is enabled on the target and the module provisions the deploy user
- **THEN** the account is absent from the login-screen user list (system uid, not a normal user)

#### Scenario: SSH activation works with a system account

- **WHEN** the deployer connects to the target by SSH using the deploy user's key
- **THEN** login succeeds and `nix copy`, pointer writes, and `systemctl start nixtache-apply.service` (polkit) are available

#### Scenario: Configuration with deploy-user is not a normal user

- **WHEN** the target configuration is evaluated with `autoProvision = true`
- **THEN** `users.users.<name>.isNormalUser` is unset (false), `isSystemUser = true`, and the uid is allocated from the system range

### Requirement: Minimal deploy-user privileges

The deploy user MUST be limited to key-based SSH login, nix-daemon access, pointer writes via `nixtache-deploy`, and start-only polkit for apply/dry (plus A/B triggers for A/B). The user MUST NOT belong to `wheel` or have sudo/doas/run0. Unconditional `trusted-users` membership is required for serve-write.

#### Scenario: Provisioned user is unprivileged

- **WHEN** the module provisions the deploy user with defaults
- **THEN** the user belongs only to the `nixtache-deploy` group (plus unconditional trusted-users for nix-daemon), is absent from `wheel`, and has no sudo/doas/run0

### Requirement: Manually managed user is asserted

With `deployUser.autoProvision = false`, the module MUST assert that `users.users.<name>` exists (a clear evaluation error otherwise), while still adding the user to `nixtache-deploy` and generating the polkit rule for that name. A consumer provisioning the user manually SHOULD make it a system account (uid < 1000); the module MUST warn if the manual user is a normal user (visible in the DM).

#### Scenario: Missing manual user fails evaluation

- **WHEN** `autoProvision = false` and `users.users.<name>` is not declared
- **THEN** evaluation fails with an error naming the missing deploy user

#### Scenario: Manual normal user warns

- **WHEN** `autoProvision = false`, the user exists, but `isNormalUser = true`
- **THEN** evaluation warns that the account is visible in login screens

### Requirement: Deploy-key SSH session is gated

With `autoProvision = true`, the module MUST restrict the deploy key with the `restrict,command=<gate>` prefix. The gate MUST accept only the exact validated protocol commands in the scenarios, including serve without shell chaining and pointer forms with store-path validation. Arbitrary commands and unapproved chaining/redirection, pty/X11/agent/port-forwarding MUST be rejected with a clear message. The `restrict`-only option MUST disable the gate for protocol drift.

#### Scenario: Port forwarding is forbidden

- **WHEN** the key holder opens an SSH connection with `-L`/`-R`/`-D` (tunneling)
- **THEN** the `restrict` option rejects the connection and no tunnel is established

#### Scenario: Arbitrary command is rejected by the gate

- **WHEN** the key holder attempts a command outside the deploy protocol (for example, launching a shell or reading arbitrary files)
- **THEN** the gate rejects it with a message listing allowed command forms; nothing executes on the target

#### Scenario: Deploy protocol passes unchanged

- **WHEN** the action performs a probe, `nix copy`, apply/dry triggers, the remote A/B command `systemctl start --wait systemd-sysupdate.service && systemctl start systemd-sysupdate-reboot.service`, or the local-self signal via `ab-pending` + `nixtache-ab-apply.service`
- **THEN** the gate accepts these exact forms; pointer and dry-pointer are allowed only with a valid `/nix/store/...` path

#### Scenario: Restrict-only escape hatch

- **WHEN** the consumer switches the gate option to `restrict`-only mode
- **THEN** authorized_keys carries only the `restrict` prefix (without `command=`), commands run as before, and evaluation requires no action changes

#### Scenario: Manually managed key without a gate warns

- **WHEN** `autoProvision = false` and the consumer manages authorized_keys directly
- **THEN** the module cannot enforce the prefix and warns with a ready-to-use recommended prefix (the `restrict,command=...` string) for manual application

### Requirement: Gate allows the disk-space query

The SSH gate whitelist SHALL additionally allow the exact, read-only
free-space query command issued by the deploy action's pre-copy check (an
exact-match command string reporting free space in bytes on the store
filesystem mount). The gate MUST continue to reject any variant form of the
command (extra arguments, redirections, chaining), and the query MUST NOT
grant any capability beyond reporting free space.

#### Scenario: The action's free-space query passes the gate

- **WHEN** the deploy action issues the whitelisted free-space query through
  the deploy key on a target with `sshGate = "gate"`
- **THEN** the gate executes it and returns the free-space value; nothing on
  the target is modified

#### Scenario: Mutated query forms are rejected

- **WHEN** the command deviates from the exact whitelisted form (extra
  arguments, shell chaining, redirection)
- **THEN** the gate rejects it with the standard not-allowed message and
  nothing executes on the target

#### Scenario: Protocol-drift transition stays available

- **WHEN** a consumer runs a new action (which issues the query) against a
  target whose still-active generation carries a pre-change gate
- **THEN** the gate rejects the query, the action skips that target with a
  warning (the job stays green), and the consumer can temporarily set
  `sshGate = "restrict"` on the target (documented migration path) until
  both sides carry the new protocol, after which the gate is re-enabled

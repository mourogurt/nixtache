# deploy-user Delta

## ADDED Requirements

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

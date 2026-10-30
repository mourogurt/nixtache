# Spec Delta

## ADDED Requirements

### Requirement: Runner overlay state follows the host upper metaslot

In runner `overlay` mode on an A/B appliance, the runner upper directory and its upper-owned Nix state MUST belong to the same physical-slot metaslot as the host store beneath it. Preparation and rollback MUST switch the host and runner layers as one coherent cascade.

#### Scenario: Target preparation repairs the cascade in order

- **WHEN** a target metaslot contains both host and runner overlay layers
- **THEN** the host layer is seeded and repaired against the new lower first, and the runner layer is then validated against that prepared host merged store

#### Scenario: Rollback restores both runner and host uppers

- **WHEN** a new slot fails boot health and the previous slot boots
- **THEN** the runner container sees the previous host lower, previous host upper and previous runner upper together, and its earlier CI store remains usable without reverse reconciliation

#### Scenario: Runner changes do not leak into the other slot

- **WHEN** CI builds or profile changes write to the active runner upper
- **THEN** those writes do not modify the inactive slot's runner upper or upper database

#### Scenario: An ephemeral host layer resets its descendant

- **WHEN** a host upper in the cascade is ephemeral and the machine reboots
- **THEN** the dependent runner upper and its upper-owned state are also reset so no records survive for files lost from the host upper

### Requirement: Runner clone mode remains independent of upper metaslots

The full relocated store used in runner `clone` mode MUST retain its additive seeding behavior and MUST NOT be duplicated into per-slot upper metaslots as though it were an OverlayFS upper.

#### Scenario: Clone store survives a slot swap additively

- **WHEN** a runner in clone mode boots another prepared A/B slot
- **THEN** its existing relocated store is retained and the new lower closure is seeded additively without cloning the store into a second slot-owned copy

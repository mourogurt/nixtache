# ab-ota Delta

## ADDED Requirements

### Requirement: The trigger reboots only after a completed installation

The AB update trigger's reboot leg SHALL reboot the target only when
`systemd-sysupdate` reported a successful installation on that trigger. When
the update installed nothing — because nothing was staged, the transfer
failed, or verification rejected the payload — the trigger SHALL leave the
target running and surface the sysupdate failure, so callers see the actual
error instead of a reboot followed by timeouts on artifacts that never
landed.

#### Scenario: failed transfer does not reboot

- **WHEN** a trigger runs, the staged v2 artifacts are unreachable, and
  sysupdate installs nothing
- **THEN** the target is not rebooted and the trigger reports the sysupdate
  failure

#### Scenario: successful install reboots into the new slot

- **WHEN** sysupdate reports `Successfully installed` for a new version
- **THEN** the reboot leg reboots the target and the new slot's marker
  artifacts (slot `.efi`, relabelled partition) are present before the
  reboot begins

### Requirement: Slot filesystem variants are boot-equivalent

Every slot filesystem variant the ab-image module can produce — at minimum
squashfs and erofs — SHALL yield an appliance that boots to
`boot-complete.target` with `/nix/store` mounted and readable. A variant
that builds but cannot boot is a defect, not a supported mode.

#### Scenario: erofs appliance boots

- **WHEN** an appliance image is built with an erofs nix-store partition
  and booted in a VM
- **THEN** the kernel console produces boot output, the system reaches
  `boot-complete.target`, and `/nix/store` is mounted readable from the
  erofs partition

#### Scenario: squashfs appliance boots

- **WHEN** an appliance image is built with a squashfs nix-store partition
  and booted in a VM
- **THEN** the system reaches `boot-complete.target` and `/nix/store` is
  mounted readable from the squashfs partition

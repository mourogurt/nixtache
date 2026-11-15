# Spec Delta

## ADDED Requirements

### Requirement: Relocated store socket activation uses Nix's expected descriptor name

For every relocated store, the custom daemon socket SHALL pass its listening descriptor as `nix-daemon.socket`. The descriptor name SHALL be independent of the custom unit name and socket path so Nix versions that filter activated descriptors by name can serve clients.

#### Scenario: Nix 2.35 accepts the relocated daemon socket

- **WHEN** a runner with a relocated store runs Nix 2.35 or newer and a client connects to the custom daemon socket
- **THEN** systemd supplies the descriptor as `nix-daemon.socket`, and the daemon accepts and serves the connection without renaming the custom unit or changing the socket path

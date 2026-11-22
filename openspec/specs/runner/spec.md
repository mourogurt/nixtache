# runner Specification

## Purpose

Runs Forgejo Actions CI jobs in a dedicated NixOS container with explicitly
controlled resource usage, so builds coexist with other services on a shared
host and consumers can size and diagnose the container themselves.

## Requirements

### Requirement: Container memory budget

The module SHALL expose `services.nixtache.runner.memoryMax` and
`memoryHigh` options, applied as the hard (`MemoryMax`) and throttling
(`MemoryHigh`) memory limits of the `container@<name>` systemd unit. The
defaults SHALL be `"16G"` and `"14G"` — a budget sized for a host shared with
other services.

#### Scenario: Default budget fits a shared host

- **WHEN** the runner module is enabled and `memoryMax`/`memoryHigh` are not set
- **THEN** the container unit evaluates with `MemoryMax=16G` and `MemoryHigh=14G`

#### Scenario: Consumer overrides the budget

- **WHEN** the consumer sets `memoryMax = "32G"` and `memoryHigh = "30G"`
- **THEN** the container unit carries exactly `MemoryMax=32G` and `MemoryHigh=30G`

### Requirement: Container swap ceiling

The module SHALL expose `services.nixtache.runner.memorySwapMax`, applied as
`MemorySwapMax` on the container unit. It SHALL default to unset, imposing no
module-level swap ceiling, so host swap (e.g. zram) remains fully available to
absorb build memory peaks.

#### Scenario: No ceiling by default

- **WHEN** `memorySwapMax` is not set
- **THEN** the container unit carries no `MemorySwapMax` directive

#### Scenario: Consumer sets a ceiling

- **WHEN** the consumer sets `memorySwapMax = "8G"`
- **THEN** the container unit carries `MemorySwapMax=8G`

### Requirement: Container CPU fairness weight

The module SHALL expose `services.nixtache.runner.cpuWeight` (integer
1..10000), applied as `CPUWeight` on the container unit to set its CPU share
relative to co-hosted services under contention. It SHALL default to unset,
keeping the systemd default weight.

#### Scenario: No weight by default

- **WHEN** `cpuWeight` is not set
- **THEN** the container unit carries no `CPUWeight` directive

#### Scenario: Consumer sets a weight

- **WHEN** the consumer sets `cpuWeight = 200`
- **THEN** the container unit carries `CPUWeight=200`

### Requirement: Container IO fairness weight

The module SHALL expose `services.nixtache.runner.ioWeight` (integer
1..10000), applied as `IOWeight` on the container unit to set its IO share
relative to co-hosted services under contention. It SHALL default to unset,
keeping the systemd default weight.

#### Scenario: No weight by default

- **WHEN** `ioWeight` is not set
- **THEN** the container unit carries no `IOWeight` directive

#### Scenario: Consumer sets a weight

- **WHEN** the consumer sets `ioWeight = 50`
- **THEN** the container unit carries `IOWeight=50`

### Requirement: Resource sizing and kill-diagnostics documentation

The documentation SHALL explain memory/swap sizing, the
`nixSettings.cores`-vs-headroom trade-off, and signal-9 diagnostics using
`machine.slice` cgroup counters, kernel logs, host/container systemd-oomd,
CI cancellation evidence, and cross-daemon UID-cleanup evidence.

#### Scenario: Consumer sizes the container

- **WHEN** a consumer needs to fit the runner container into a host RAM budget
- **THEN** the documentation explains memory/swap sizing and the
  cores-vs-memory trade-off, without requiring source-code reading

#### Scenario: Consumer diagnoses a killed build

- **WHEN** a CI build dies with "builder failed due to signal 9"
- **THEN** the documentation provides a diagnostic decision tree covering
  cgroup OOM counters, kernel logs, both systemd-oomd layers, CI-side job
  cancellation, and UID-wide cleanup by an independent Nix daemon

#### Scenario: Consumer correlates concurrent daemon builds

- **WHEN** a killed CI build coincided with a host Nix build
- **THEN** the documentation explains how to compare numeric builder UIDs and daemon cleanup evidence on both sides

### Requirement: Relocated store socket activation uses Nix's expected descriptor name

For every relocated store, the custom daemon socket SHALL pass its listening descriptor as `nix-daemon.socket`. The descriptor name SHALL be independent of the custom unit name and socket path so Nix versions that filter activated descriptors by name can serve clients.

#### Scenario: Nix 2.35 accepts the relocated daemon socket

- **WHEN** a runner with a relocated store runs Nix 2.35 or newer and a client connects to the custom daemon socket
- **THEN** systemd supplies the descriptor as `nix-daemon.socket`, and the daemon accepts and serves the connection without renaming the custom unit or changing the socket path

### Requirement: Custom daemon uses isolated builder identities

For every relocated store, `nix-daemon-custom` SHALL use a dedicated static builder group and accounts whose numeric UIDs/GID are disjoint from the host Nix builder IDs. Custom-daemon builds MUST NOT run as root or use automatic UID allocation, and the container's system daemon SHALL retain its independent builder configuration.

#### Scenario: Nix-enabled host runs two daemon configurations

- **WHEN** the runner uses a relocated store on a Nix-enabled host
- **THEN** the custom daemon builds through its dedicated group and UIDs while the container system daemon keeps its existing `nixbld` configuration

#### Scenario: Appliance custom daemon builds without root

- **WHEN** the runner uses a relocated store in either clone or overlay mode on a Nix-less appliance host
- **THEN** the custom daemon has dedicated build users and completes builds as those non-root users

#### Scenario: Automatic UID allocation cannot bypass isolation

- **WHEN** automatic UID allocation is enabled elsewhere in the container Nix configuration
- **THEN** the custom daemon still allocates builds only from its dedicated static builder accounts

### Requirement: Independent daemon cleanup cannot kill another build

Host and runner-container Nix daemons SHALL use disjoint numeric builder UIDs so UID-based cleanup by one daemon cannot terminate processes belonging to a concurrent build owned by the other daemon.

#### Scenario: Host build cleanup preserves the container build

- **WHEN** host and custom-daemon builds are running concurrently and the host build finishes or is cancelled
- **THEN** host cleanup does not signal the container builder, which remains alive and can complete its output

#### Scenario: Container build cleanup preserves the host build

- **WHEN** host and custom-daemon builds are running concurrently and the container build finishes or is cancelled
- **THEN** custom-daemon cleanup does not signal the host builder, which remains alive and can complete its output

### Requirement: Declarative host ID collisions are rejected

The module SHALL reject a relocated-store configuration when a dedicated custom-builder UID or GID overlaps a statically declared host user or group ID, rather than allowing unsafe concurrent daemon operation.

#### Scenario: Host account occupies the dedicated range

- **WHEN** a statically declared host user or group occupies an ID selected for the custom builder accounts or group
- **THEN** evaluation fails with an error identifying the ID collision before either daemon can run with overlapping builder identities

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
- **THEN** it contains the bare runner token — no `TOKEN=` prefix and no
  environment-file syntax; the uuid + token pair is obtained from Forgejo
  when the registration is created

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
`[ "nixos:host" ]`. The module SHALL NOT expose a runner-name option: the
name is fixed in Forgejo when the registration is created, so
`instances.<name>.name` SHALL fail evaluation as an unknown option.

#### Scenario: Labels reach the instance settings

- **WHEN** an instance sets `labels = [ "test:host" ]`
- **THEN** the in-container instance's `settings.runner.labels` is
  `[ "test:host" ]`

#### Scenario: Runner name is not settable

- **WHEN** a consumer sets `instances.default.name`
- **THEN** evaluation fails with an unknown-option error

### Requirement: Container nix daemon trusts the runner service users

The in-container `nix.settings.trusted-users` SHALL include
`forgejo-runner-<name>` — the NSS-visible name of the dynamic user of each
`forgejo-runner-<name>.service` — for every enabled instance. Host-mode jobs
therefore stay trusted nix clients: they may use the configured substituters
and copy closures out of the store (direct deploy).

#### Scenario: Trusted users track the instances

- **WHEN** instances `default` and `test` are enabled
- **THEN** the container's `nix.settings.trusted-users` contains
  `forgejo-runner-default` and `forgejo-runner-test` for those registrations

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

### Requirement: Runner container operates on a nix-less appliance host

When the host has nix disabled (`nix.enable = false`, e.g. an A/B appliance), the runner container MUST run with its own nix module disabled, the module MUST render the container's `nix.conf` itself while preserving the configured system-features, substituters and trusted-users, and the nix CLI MUST be shipped explicitly. Operation over the appliance's input-addressed lower closure MUST NOT require `ca-derivations`.

#### Scenario: Container starts and serves CI on an appliance host

- **WHEN** the runner module is enabled on a host with `nix.enable = false` and an input-addressed appliance lower store
- **THEN** the container starts, evaluates with its internal nix module disabled, and exposes a working nix CLI governed by the module-rendered `nix.conf` without requiring CA derivation support

#### Scenario: Runner store operations accept snapshot-derived lower records

- **WHEN** a runner seeds a clone store or opens an overlay lower from an appliance's snapshot-derived database with CA derivation support disabled
- **THEN** all shipped lower paths retain their validity and references, closure copying completes without NAR hash mismatches, and subsequent CI store operations succeed

### Requirement: Clone mode seeds from the real host store database

In clone mode on an appliance host, the storage seeder MUST enumerate the host store through a writable scratch copy of the host's store database, so the relocated store receives every path registered in the shipped lower database.

#### Scenario: Clone receives the host store closure on an appliance

- **WHEN** the runner container's storage seeder runs on an appliance host in clone mode
- **THEN** the seed copies every path registered in the host store's database into the relocated store, and post-seed CI builds resolve host-store paths locally

### Requirement: Overlay mode uses a local lower store on appliance hosts

In overlay mode on a nix-less host, the custom daemon MUST use a dedicated read-only local lower outside its relocated `/nix`. A slot-scoped lower MUST contain the selected parent's frozen files and metadata, never its mutable runtime continuation or a copied metadata-only snapshot.

#### Scenario: Overlay daemon serves a coherent merged view on an appliance

- **WHEN** the runner container runs in overlay mode on an appliance host
- **THEN** the overlay store opens the dedicated read-only local lower, lower paths resolve with their validity records, builds write to the upper layer, and no daemon self-connection loop occurs

#### Scenario: Selected parent metadata survives the runner /nix rebind

- **WHEN** a slot-scoped host or parent runner lower is selected and the child runner's custom daemon rebinds `/nix` to its merged relocated store
- **THEN** the child resolves lower paths through the frozen parent's store and metadata at the dedicated read-only root outside `/nix`, without treating its own upper database as the lower

#### Scenario: Parent runtime writes wait for a child rebase

- **WHEN** the parent's own runtime continuation gains a new rooted path while a child runner is running
- **THEN** the child lower remains unchanged until a later prepared generation incorporates that runtime state into a new frozen parent lower and restarts the child into it

#### Scenario: Rebased parent metadata is fresh after restart

- **WHEN** a new prepared generation freezes the parent's previous runtime continuation and the child runner starts against that generation
- **THEN** the child resolves both the parent files and their current validity records without a live SQLite read, a metadata-only copy or access to a write-capable parent daemon socket

### Requirement: The runner store survives OTA slot swaps

On an appliance runner host (`method = "ab-image"`), the runner's relocated
store MUST remain functional across OTA slot swaps without manual repair:
in clone mode the post-swap re-clone is additive and keeps serving builds;
in overlay mode the merged view remounts coherently over the new lower.
The runner container's wiring MUST NOT assume a host nix daemon or host
store database on an appliance (whose host has nix disabled).

#### Scenario: Clone mode keeps building after a swap

- **WHEN** the runner uses a cloned relocated store, an OTA update swaps
  the active slot, and the machine reboots into the new image
- **THEN** the re-clone after the swap is additive (previously cloned paths
  kept, new lower paths added) and a CI build through the relocated store
  succeeds

#### Scenario: Overlay mode stays coherent after a swap

- **WHEN** the runner uses an overlay relocated store, an OTA update swaps
  the active slot, and the machine reboots into the new image
- **THEN** the overlay remounts over the new lower and a CI build through
  the relocated store succeeds

#### Scenario: No host-daemon assumptions on an appliance

- **WHEN** the runner container runs on an appliance whose host has nix
  disabled
- **THEN** the container's store services come up without a host nix-daemon
  unit and without bind-mounts of the host store database/socket that would
  break the container's custom daemon

### Requirement: A/B signing key is consumed through credentials

When `runner.deploy.ab.signingKeyFile` is configured, both the in-container
runner services and the host `nixtache-ab-gc.service` SHALL receive the key as
`sysupdate_signing_key` through systemd `LoadCredential`. Their scripts SHALL
read it from `$CREDENTIALS_DIRECTORY`, not from the original host path.

#### Scenario: Host retain-GC signs through its credential

- **WHEN** the host retain-GC regenerates a staging manifest with a signing key
  configured
- **THEN** the unit has `LoadCredential = sysupdate_signing_key:<signingKeyFile>`
  and GPG imports `$CREDENTIALS_DIRECTORY/sysupdate_signing_key`, producing a
  verifiable signature without reading the original path in the script

#### Scenario: Deploy action uses the same credential contract

- **WHEN** a deploy job signs a staging manifest
- **THEN** its runner service exposes the same credential name and the action
  imports it from its job credentials directory

#### Scenario: No signing key leaves no credential

- **WHEN** `signingKeyFile = null`
- **THEN** neither service receives the signing credential and retain-GC removes
  stale detached signatures rather than presenting them as current

### Requirement: Runner overlay state follows the host upper metaslot

In runner `overlay` mode on an A/B appliance, every runner upper directory and its upper-owned Nix state MUST belong to the same physical-slot metaslot as the host store beneath it. Preparation and rollback MUST switch the host and all runner layers as one coherent tree, regardless of whether runner containers are siblings or nested inside one another.

#### Scenario: Target preparation repairs the tree in order

- **WHEN** a target metaslot contains a host upper and one or more runner overlay nodes
- **THEN** the host layer is seeded and repaired against the new physical lower first, every other parent's frozen lower is prepared before its children, and each runner node is validated against its own prepared parent's frozen lower

#### Scenario: Rollback restores every runner and host upper

- **WHEN** a new slot fails boot health and the previous slot boots
- **THEN** each runner container sees the previous physical lower and its complete previous ancestor and upper chain together, and its earlier CI store remains usable without reverse reconciliation

#### Scenario: Runner changes do not leak into another slot or sibling

- **WHEN** CI builds or profile changes write to an active runner upper
- **THEN** those writes do not modify the inactive slot's upper tree, a sibling runner upper or any sibling upper database

#### Scenario: An ephemeral layer resets its complete descendant subtree

- **WHEN** any host or runner upper in the tree is ephemeral and the machine reboots
- **THEN** every descendant runner upper and its upper-owned state are also reset so no records survive for files lost from an ancestor upper

### Requirement: Runner declarations derive the internal overlay topology

Users MUST declare runner containers and store-parent relationships through runner options. The module MUST derive layer identities, parent edges, frozen lowers, runtime continuations, lower roots and managed paths internally, without a parallel consumer-facing `layers` list.

#### Scenario: Sibling declarations generate sibling layers

- **WHEN** two enabled runner containers name the host as their store parent
- **THEN** the module derives two independent overlay nodes over the same frozen host lower, including their upper/work/state paths and dedicated lower roots

#### Scenario: A nested declaration generates a frozen lower and continuation

- **WHEN** a runner container names another runner container as its store parent
- **THEN** the module derives the parent's immutable lower, a runtime continuation for the parent's own container and a child branch over that lower, rather than wiring the child to the mutable continuation

#### Scenario: Clone and native stores do not generate upper-metaslot nodes

- **WHEN** a runner uses clone mode or its native `/nix` store
- **THEN** no slot-scoped overlay node is generated for that runner, and an overlay child cannot select it as an overlay parent

#### Scenario: Invalid declarations fail before runtime changes

- **WHEN** a named parent is missing, parent edges form a cycle, identities are unsafe or derived managed paths collide
- **THEN** evaluation rejects the configuration before any container, mount or metaslot is changed

### Requirement: Runner topology changes are operation-based

Runner configurations MUST support addition, reparenting and removal at any breadth or depth without assuming a fixed production tree. Target preparation MUST use the target declarations; the active graph MUST remain unchanged until the complete new graph is ready. State retention follows `upperOnUpdate`: `reconcile` preserves eligible branches, while `wipe` creates clean target state.

#### Scenario: Add operations converge in breadth and depth

- **WHEN** a target configuration adds a sibling or a deeper descendant to an existing runner graph under `reconcile`
- **THEN** production runner wiring and internal layers are generated for the new graph, unchanged branches retain their state, and the final target passes the same parent-first and isolation checks as any other graph

#### Scenario: Wipe derives the same graph with clean state

- **WHEN** any runner topology operation is prepared under `wipe`
- **THEN** production runner wiring converges to the same final graph with clean writable upper/state while the active graph remains unchanged until cutover

#### Scenario: Reparent operations converge with their descendants

- **WHEN** a target configuration moves a runner and its subtree to another store parent
- **THEN** the moved runner and descendants are prepared against the new frozen parent, their previous duplicated lower metadata is not accepted as current, and the old active graph remains available until cutover

#### Scenario: Remove operations converge without implicit adoption

- **WHEN** a target configuration removes a runner leaf, or removes a subtree through explicit descendant removal or reparenting
- **THEN** its runtime wiring disappears from the target, remaining branches stay coherent, and no child is silently attached to the removed node's former parent

#### Scenario: Rollback restores the previous declared graph

- **WHEN** a target boot fails after a runner topology operation
- **THEN** rollback selects the previous lower, runner declarations, internal frozen lowers and runtime continuations as one preserved graph

### Requirement: Sibling and nested runner overlays compose into one metaslot

Runner overlay preparation MUST NOT assume a fixed host-to-single-runner cascade. Stable runner node identities and parent relationships MUST support multiple containers over one frozen host lower, containers nested over another runner's frozen lower, and compositions of those shapes. All runner nodes MUST share the metaslot's atomic readiness and rollback boundary while retaining independent uppers and state.

#### Scenario: Two runner containers share the host lower

- **WHEN** two runner containers are siblings over the frozen host lower and CI roots exist in the host and in both containers
- **THEN** target host frozen-lower repair completes before either runner repair, both containers validate their roots against that frozen view, and CI writes or missing-path repairs in one container never appear in the other

#### Scenario: A nested runner container consumes the middle runner store

- **WHEN** a second runner container runs inside a first runner container and the first runner's frozen lower is the second runner's lower
- **THEN** target preparation verifies the first runner's own roots before preparing the second, and the second resolves its parent-provided closure through the prepared first runner's frozen lower rather than the host, active tree or first runner's runtime continuation

#### Scenario: Middle and leaf CI roots exercise cross-layer closure repair

- **WHEN** the first and nested second runner both root a closure that needs repair, while the second also has an independent leaf-only root
- **THEN** the shared portion is available through the prepared middle frozen lower, the leaf-only portion is repaired only in the second runner, and their duplicated closure metadata is valid throughout the target tree

#### Scenario: A composed sibling-and-nested tree has one readiness result

- **WHEN** one host has two runner children and one of those runners has a nested runner child
- **THEN** every intermediate and leaf is prepared in topological order, a failure in any runner blocks the whole target metaslot, and rollback later selects the complete previous tree without reverse repair

### Requirement: Runner clone mode remains independent of upper metaslots

The full relocated store used in runner `clone` mode MUST retain its additive seeding behavior and MUST NOT be duplicated into per-slot upper metaslots as though it were an OverlayFS upper.

#### Scenario: Clone store survives a slot swap additively

- **WHEN** a runner in clone mode boots another prepared A/B slot
- **THEN** its existing relocated store is retained and the new lower closure is seeded additively without cloning the store into a second slot-owned copy

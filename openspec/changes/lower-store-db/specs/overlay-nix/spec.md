# Spec Delta

## ADDED Requirements

### Requirement: Runtime installs are delta against the valid lower store

With the appliance shipping a store database for the lower closure, realizing a path whose closure (or parts of it) is already valid in the lower store MUST NOT copy those paths into the upper layer; only paths missing from the merged store land in the upper.

#### Scenario: Partially-lowered closure installs as a delta

- **WHEN** a package is realized whose closure partially exists as valid entries in the lower store's database
- **THEN** the already-valid paths are served from the lower and never copied into the upper; only the missing paths are fetched into the upper layer

#### Scenario: A lower-only path needs no upper copy

- **WHEN** a store path that ships in the lower image is realized or referenced at runtime
- **THEN** no copy of it appears in the upper layer, and its validity resolves from the shipped database out of the box (no manual seeding)

### Requirement: Upper lifecycle across OTA updates is a wipe-or-reconcile choice

The module MUST offer an explicit lifecycle policy for the upper layer across OTA updates (option `upperOnUpdate`) with exactly two values: `"wipe"` (the default — deterministic, substituter-independent) and `"reconcile"` (delta repair; needs a substituter serving the old references). With the lower store database shipped, carrying the upper across a swap only produces dangling references, so no carry-over value exists.

#### Scenario: The carried-upper value is rejected

- **WHEN** a configuration sets `upperOnUpdate = "none"`
- **THEN** evaluation fails with an error naming the two valid values (`"wipe"`, `"reconcile"`)

#### Scenario: Default policy wipes the upper at update cutover

- **WHEN** the option is not set and an OTA update is triggered (CI trigger, idle-gated apply, or auto-update poll)
- **THEN** the upper layer and its database entries are cleared before the inactive slot is written, and after the swap the shipped lower database is re-seeded and the overlay remounts over the new lower with a functional merged store (new lower paths visible, nix usable, no stale upper content)

#### Scenario: Reconcile heals dangling references from the substituter

- **WHEN** `upperOnUpdate = "reconcile"`, the machine has rebooted into a new lower image, and an upper-layer tool's closure references paths missing from the merged view that the configured substituter can provide
- **THEN** a post-boot reconcile pass invalidates database entries whose files are gone, re-fetches only the missing referenced paths, and the previously broken upper-layer tool runs again — without reinstalling the whole upper layer

#### Scenario: Reconcile degrades safely without the substituter

- **WHEN** `upperOnUpdate = "reconcile"` and a dangling reference cannot be re-fetched (substituter unreachable or lacks the path)
- **THEN** the reconcile unit completes the boot sequence unaffected and reports the unrepaired paths (failing status with a journal record naming them) rather than blocking boot or deleting unrelated upper content

#### Scenario: Recorded installables are replayed after the swap

- **WHEN** `upperOnUpdate = "reconcile"` and profile installables were recorded before the update whose entire closure was invalidated by the swap
- **THEN** the reconcile pass re-installs the recorded installables after the repair step, so the recorded user-facing tools are runnable again

## MODIFIED Requirements

### Requirement: Full nix surface over a read-only store

With the overlay enabled on an A/B appliance, nix MUST be re-enabled and usable through the standard system daemon: ad-hoc realize, run, shell, build, profile install and garbage collection all operate on the merged view, writes for paths not already valid in the lower store land in the configured upper layer, the lower image partition is never mutated, and the daemon's configuration enables the `ca-derivations` experimental feature so runtime evaluation (e.g. profile installs) works over the fleet's content-addressed closure.

#### Scenario: Install a package at runtime on an appliance

- **WHEN** a package is realized (or profile-installed) from a configured substituter on an appliance whose `/nix/store` is a read-only image
- **THEN** the package's store paths not already valid in the lower store land under the configured upper layer, the binary runs through the merged `/nix/store`, and the lower layer's content is byte-identical to the image

#### Scenario: Runtime evaluation works over the content-addressed closure

- **WHEN** a profile install evaluates nixpkgs on an appliance whose lower closure is content-addressed
- **THEN** the daemon accepts the `ca:fixed:r:` derivations (the feature is enabled in its configuration) and the install completes against the merged view

#### Scenario: The overlay is mounted before the daemon serves requests

- **WHEN** the appliance boots
- **THEN** the OverlayFS at `/nix/store` (lower = image partition, upper = configured upper layer) is active before the nix daemon serves any request, so every nix command observes the merged view

### Requirement: Store-database coherence across an OTA swap is observable

When an OTA slot swap replaces the lower store while the upper layer (and its database entries) persist, upper-layer paths whose references existed only in the old lower MUST fail deterministically (missing interpreter or library — a hard execution error), and standard nix tooling MUST be able to report the incoherence: a store-database entry whose files are absent from the merged view — whether an upper entry or a stale old-lower record left by the additive swap merge — is detected by the store verification command.

#### Scenario: Upper path referencing an old-lower-only path fails

- **WHEN** an upper-layer tool's closure references a store path that was valid only in the pre-update lower image, and the tool is executed after the swap
- **THEN** execution fails with a missing-file error (no partial or silent misbehaviour), and the missing reference is identifiable from the error

#### Scenario: Verification reports dangling database entries

- **WHEN** the store verification command runs after such a swap
- **THEN** paths registered as valid whose files are absent from the merged view are reported (and are not silently treated as healthy)

## REMOVED Requirements

### Requirement: Upper lifecycle across OTA updates is configurable

**Reason**: the `"none"` value preserved a world-B accident — the upper survived swaps only by closure completeness; with the lower store database shipped, carrying the upper across a swap deterministically produces dangling references. The state space is OTA on/off × overlay on/off, and when both are on the only question is wipe-vs-reconcile — a no-op value has no meaningful behavior left.

**Migration**: configurations that never set the option move to the new `"wipe"` default (the upper is cleared at the next update); configurations setting `upperOnUpdate = "none"` explicitly fail evaluation with the enum error naming `"wipe"` and `"reconcile"` — operators relying on the carried upper MUST switch to `"reconcile"` (with a substituter configured) before deploying.

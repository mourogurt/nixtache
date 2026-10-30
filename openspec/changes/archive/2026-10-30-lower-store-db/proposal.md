# Proposal

## Why

An A/B appliance's lower store (the slot squashFS/erofs) ships with no Nix
database: the image-based-appliance profile disables nix, and nothing records
validity for the slot closure. The missing lower DB is the hidden root cause
behind three broken surfaces, all surfaced by `server-ab-migration-prep`'s
attempt to run the runner on a real appliance:

1. **Runner clone mode** seeds by enumerating the host store's DB — empty on
   an appliance, so the clone copies nothing.
2. **Runner overlay mode** sets `lower-store=daemon`, but no system daemon
   can exist in a container on a nix-less host (the RO-bound socket dir can't
   create a socket) — the custom daemon self-references and fork-loops.
3. **overlay-nix stays in "world B"**: with no lower validity records, every
   runtime install drags its full closure into the upper layer, and the
   upper survives slot swaps only by accident of closure completeness. The
   world-A machinery (dangling-reference detection, `upperOnUpdate`
   reconcile) exists but is not the shipped reality.

Shipping a build-time-generated store DB for the slot closure makes the
lower a first-class readable store and fixes all three at the root.

## What Changes

- **`ab-image` ships the lower DB**: at image build time, the toplevel
  closure's *registered* validity records (`pkgs.closureInfo`'s
  `registration` — trustworthy because the fleet is content-addressed, see
  the next bullet) are shipped as a dump and loaded into `/nix/var/nix/db`
  at boot when the DB is missing (first boot, and after `upperOnUpdate =
  "wipe"` cleared it). The store itself is imaged faithfully: closure paths
  that are top-level symlinks ship as symlinks (a store tree feeds the
  image builder one copy source, so no path is dereferenced individually).
- **Content-addressed fleet (CA pivot)**: the OTA + overlay-nix target's
  nixpkgs evaluation runs `config.contentAddressedByDefault = true`, and
  the `ca-derivations` experimental feature is enabled in every
  module-rendered nix.conf that evaluates derivations (runner container,
  appliance runtime, build side). DB-inherited narHashes become
  content-true by construction, so the interim per-path content-hashing
  dumper is deleted; the fleet's single nix-serve cache holds IA and CA
  realisations side by side during the migration.
- **Swap semantics**: after a slot swap the new slot's records load
  additively; stale old-slot records remain detectable by
  `nix-store --verify` and are healed by the existing reconcile pass — the
  world-A coherence machinery becomes the shipped default reality.
- **Runner container appliance wiring**: on a nix-less host the container
  runs with `nix.enable = false` (the standalone store branches in
  `store.nix` activate), keeps its `nix.conf` (rendered directly, since the
  nix module no longer writes it) and ships the nix CLI explicitly; the
  overlay store URL switches to `lower-store=local` there (the RO-bound host
  DB is real now, so a local lower opens fine). Clone mode seeds from a
  scratch copy of the real DB — enumeration works.
- **overlay-nix world A transition**: installs against the overlay become
  delta (only paths missing from the merged store land in the upper). The
  persistence/coherence scenarios are reworked for world A, and
  `upperOnUpdate` loses its `"none"` value (a carried upper now only
  produces dangling references): the enum shrinks to `"wipe"` (new
  default — the only policy safe with zero prerequisites) and
  `"reconcile"` (opt-in, needs a substituter).
- **Tests**: `runner-store-swap-vm` (both modes) joins the CI matrix green;
  the overlay-nix suites drop the manual DB seed (the appliance ships
  seeded); new pins for the DB loader (pure-eval + boot-time).

## Capabilities

### New Capabilities

(none — this extends existing capabilities)

### Modified Capabilities

- `ab-ota`: the appliance image ships the lower store DB; new requirements
  covering its build-time generation, boot-time loading and lifecycle across
  slot swaps and overlay wipes, the content-addressing contract that
  makes the records content-true, faithful shipping of top-level symlink
  closure paths, and a deterministic max-disk layout (fixed ESP, root takes
  the leftover).
- `overlay-nix`: world A becomes the shipped reality — installs are delta
  against a valid lower; the persistence/coherence requirements are reworked
  accordingly, and the lifecycle policy loses its `"none"` value (new
  default: `"wipe"`).
- `runner`: the relocated store works on nix-less appliance hosts (container
  wiring + lower DB), in both clone and overlay modes.

## Impact

- `modules/ab-image/`, `modules/overlay-nix/`, `modules/runner/` (store,
  container config), `modules/auto-update` (unchanged, but interacts via the
  wipe/reconcile lifecycle).
- nix.conf surfaces rendered by the runner and overlay-nix modules gain the
  `ca-derivations` experimental feature; the image eval asserts
  `contentAddressedByDefault` on the consumer's nixpkgs. The fleet cache
  holds IA and CA realisations side by side during the transition (one
  nix-serve serves both).
- `tests/`: `runner-store-swap-vm` unblocked (joins the matrix),
  overlay-nix suites reworked to the shipped world A, `ab-contract` /
  `ab-image` eval pins for the dump + loader, new boot-time pin.
- `doc/user_guide/ota.md`, `overlay-nix.md`,
  `doc/technical_details/testing.md` updated for the new reality.
- Unblocks group 3 of `server-ab-migration-prep` (runner store across a
  swap) and the reference server's migration with the runner intact.

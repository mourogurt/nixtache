# The lower store database (appliance images)

How the A/B appliance image ships a nix store database for its read-only
slot closure, and why the dump's hashes are computed the way they are.
Functional behaviour (what loads when, lifecycle across swaps) lives in
[`doc/user_guide/ota.md`](../user_guide/ota.md); canonical requirements in
[`openspec/specs/ab-ota/spec.md`](../../openspec/specs/ab-ota/spec.md).
This document is for contributors and owns the internals.

The problem being solved: an appliance boots `nix.enable = false` with a
read-only squashFS `/nix/store` and no `/nix/var/nix/db`. Without a
database the runner container's clone mode enumerates an empty store
(copies nothing), its overlay mode's `lower-store=daemon` self-references
(no system daemon exists), and overlay installs download full closures
instead of deltas. The image therefore ships validity records (path,
narHash, narSize, references per store path) and a boot-time loader seeds
`/nix/var/nix/db` from them.

## Dump generation: registered records, content-true via content-addressing

The dump (`modules/ab-image/lower-store-db.nix`) is the toplevel closure's
REGISTERED validity records: `pkgs.closureInfo`'s `registration` output
(path, base16 narHash, narSize, deriver, references per path), one
derivation per toplevel. Trusting the daemon's DB records is justified
exactly one way — the evaluation is content-addressed, which the module
asserts (`nixpkgs.config.contentAddressedByDefault`; see below). An interim
implementation re-hashed every path's shipped bytes in python
(`nix-store --dump` per path); it was retired when the fleet moved to CA
(see git history) — two failure modes motivated it, and CA resolves only
the first:

1. **Per-host realisations (resolved by CA).** An input-addressed store path
   legitimately has *different realisations* on different hosts
   (substitution churn, older realisations accumulated in a long-lived CI
   store). The daemon's DB records what *that* host believes; `repart
   CopyFiles` ships what is in the store — and the two diverge silently.
   The divergence detonates in the production path: the runner's clone seed
   runs `nix copy --all`, which re-serializes every path and verifies it
   against the source DB's recorded narHash — a mismatch aborts the copy
   and the retry loop never converges:

   ```
   error: hash mismatch importing path '/nix/store/…-nix-2.34.8-man';
          specified: sha256:14rh8r1k…   (the DB record: a 184-byte symlink)
          got:       sha256:0c6z1cjk…   (the shipped content: 476 KB of files)
   ```

   Under `ca:fixed:r:` the path hash IS the content hash — a build computes
   content→path, substitution verifies content against the narinfo — so the
   DB cannot lie about content.

2. **repart resolves top-level symlinks (NOT resolved by CA — guarded).**
   A store path that IS a symlink to another store path ships as a real
   directory with the target's content — imaging behaviour, not hashing, so
   CA changes nothing (and rewriting the record from the resolved content
   would contradict the path↔content binding and fail verification just as
   hard). The generator therefore ships a **build-time guard**: the image
   build fails, listing any closure path that is a top-level symlink (rare;
   the offender gets repackaged). A silent runtime landmine becomes a loud
   build error.

### Enabling CA (the two knobs, and a daemon quirk)

- The evaluation-side knob is the nixpkgs config:
  `config.contentAddressedByDefault = true` on the import (the
  [wiki](https://nixos.wiki/wiki/Ca-derivations) route). There is NO
  `content-addressed-by-default` nix.conf setting (checked on nix 2.34.8).
- The `ca-derivations` experimental feature must ALSO be enabled — and,
  counterintuitively, in the **system** nix.conf of every machine that
  evaluates CA: the nix daemon ignores client-side feature overrides when
  the new CLI connects to it (NixOS/nix#9090), so `--extra-experimental-features`,
  `NIX_CONFIG` and user-level nix.conf are all ineffective for the
  evaluator's gate. The modules ship the feature where they render confs:
  the runner container's `/etc/nix/nix.conf` and the overlay appliance's
  `nix.settings` (both pinned by tests); dev machines and bare CI runners
  need it in their system configuration. Legacy `nix-instantiate` never
  opens a store connection and is unaffected.

## Carrier constraints (why the dump lives on the ESP)

- **Not `environment.etc`, not any toplevel-referenced store path**: the
  dump's derivation covers the toplevel closure, so a toplevel→dump
  reference is a derivation cycle.
- **Not inside `/nix/store`**: the `local-overlay-store`'s GC scans the
  merged store directory and hard-fails parsing any non-store-path entry
  ("'…' is too short to be a valid store path"). GC (nix `gc.cc`) skips
  only `.`, `..` and `.links` — by exact name, not by dot-prefix.

The dump therefore ships on the ESP at a versioned path
(`/EFI/nixtache/<imageId>_<version>.lower-db`) and travels across updates
via the `15-lower-db` sysupdate transfer (InstancesMax=2 — the old slot's
dump is vacuumed together with its UKI). It is part of the signed
`sysupdate-package`; every manifest-regeneration site (the deploy action,
the runner's staging retain-GC, the test harnesses) must include
`*.lower-db` in the `sha256sum` glob.

## Read-only store opens: `.links` and the remount

Two `LocalStore` constructor behaviours (nix 2.34, `local-store.cc`) bite
on an appliance whose `/nix/store` is a read-only mount without `.links`:

- `createDirs(realStoreDir)` and `createDirs(storeDir/.links)` run
  **unconditionally** — even with `read-only=true` in the store URL (that
  flag only skips `makeStoreWritable`). Opening any local store on a bare
  appliance fails with `creating directory "/nix/store/.links": Read-only
  file system`.
- `makeStoreWritable()` (writable mode, as root) attempts to **remount** a
  read-only store writable — which the squashFS/nspawn binds refuse.

Consequences wired into the modules:

- The image ships an empty `/nix/store/.links` (a `.keep` placeholder via
  the partition contents; GC may later delete the file — the directory
  stays, and that is all the constructor needs).
- The appliance's loader (`nixtache-lower-store-db-load.service`) runs
  `nix-store --load-db` inside `unshare -m --propagation private` with a
  tmpfs-upper OverlayFS over `/nix/store`: the store stays readable, the
  dir-init lands in the discarded namespace, the DB write to `/nix/var/nix`
  persists. (A unit-level `TemporaryFileSystem=/nix/store` cannot be used —
  it would mask the unit script's own store path at exec time, status
  203/EXEC.)
- The runner container's clone seed reads the host DB through a writable
  scratch copy plus a `local?root=/&state=…&read-only=true` source URL
  (the `read-only-local-store` experimental feature skips the remount;
  `.links` shipped above satisfies the init).

## Alternatives considered

- **Fixed CA (`ca = "fixed:r:sha256"` on the raw derivation)**: evaluates
  without any experimental feature, but nixpkgs exposes no switch producing
  it for regular packages — only the floating `__contentAddressed` spell
  (what `contentAddressedByDefault` sets) exists, so it is not a fleet-wide
  route.
- **Prebuilt `db.sqlite`**: merging a binary DB at runtime needs
  schema-aware tooling on the appliance; the records format is nix's own
  stable import format and merges additively by construction.

Test coverage: the dump and loader wiring are pinned by
`checks.<system>.ab-image` (pure-eval), boot-time seeding by
`vmTests.overlay-nix-vm`, the clone/overlay consumption across a real swap
by `vmTests.runner-store-swap-{clone,overlay}-vm` — see
[`testing.md`](testing.md).

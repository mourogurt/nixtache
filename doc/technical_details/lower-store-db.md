# The lower store database (appliance images)

How the A/B appliance image ships a nix store database for its read-only
slot closure, and why the dump's hashes are computed the way they are.
Functional behaviour (what loads when, lifecycle across swaps) lives in
[`doc/user_guide/ota.md`](../user_guide/ota.md); canonical requirements in
[`openspec/specs/ab-ota/spec.md`](../../openspec/specs/ab-ota/spec.md).
This document is for contributors and owns the internals.

## The problem, stated in full

An appliance slot is a squashFS/erofs image: `/nix/store` is a read-only
mount populated with the system closure, and the image-based-appliance
profile disables nix entirely (`nix.enable = false` — appliances are not
rebuilt in place). Consequently nothing ever creates `/nix/var/nix/db`,
the database that tells nix which paths exist and what their contents'
hashes are. Three consumer surfaces break on such a store:

- **Runner container, clone mode** (`services.nixtache.runner.store.mode =
  "clone"`): the storage seeder enumerates "all valid paths" through the
  host's database — with no database the enumeration is empty, and the
  clone copies nothing.
- **Runner container, overlay mode**: the overlay store URL pointed the
  lower layer at `lower-store=daemon`, but no system nix daemon exists on
  a nix-less host — the custom daemon's workers connect to their own
  socket and fork-loop.
- **Runtime installs through overlay-nix**: nix must realize the closure of
  whatever is installed — with no validity records for the lower store it
  cannot know that most of that closure already ships in the image, so it
  downloads everything into the upper layer (no delta installs).

The fix: the image build ships the closure's validity records (path,
narHash, narSize, deriver, references per store path) as a dump on the ESP,
and a boot-time loader seeds `/nix/var/nix/db` from it. The rest of this
document covers the internals: how the dump is generated, how the store is
imaged, and why the runtime workarounds exist.

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
   and the retry loop never converges. Under `ca:fixed:r:` the path hash IS
   the content hash — a build computes content→path, substitution verifies
   content against the narinfo — so the DB cannot lie about content.

2. **repart resolves top-level symlink copy sources (imaging behaviour —
   fixed by faithful imaging, works for any store).** The image builder
   (systemd-repart, pinned 261.x) populates a partition from `CopyFiles=`
   lines, and it opens every copy source through path resolution that
   follows symlinks: a source that IS a symlink to a directory ships as
   that directory's content. nixpkgs' `image.repart` `storePaths` option
   emits one `CopyFiles=` line per closure path — so a closure path that is
   itself a symlink shipped as its target's content, contradicting its
   database record. The original incident (the runner's clone seed dying in
   an infinite retry on the real appliance):

   ```
   error: hash mismatch importing path '/nix/store/…-nix-2.34.8-man';
          specified: sha256:14rh8r1k…   (the DB record: a 184-byte symlink)
          got:       sha256:0c6z1cjk…   (the shipped content: 476 KB of files)
   ```

   Such paths are standard (nixpkgs' `nix.man`/`nix.doc` outputs are
   symlinks into `nix-manual`, and the appliance ships `pkgs.nix`), and
   rewriting the record instead would be invalid under CA. The module
   therefore does not use `storePaths`: a store-tree derivation
   (`modules/ab-image/store-tree.nix`) materialises the closure at build
   time — regular paths are copied, symlink paths are recreated as
   symlinks — and the partition receives ONE `CopyFiles` line pointing at
   the tree. Only the tree itself is resolved; every entry inside is
   copied type-faithfully (systemd `copy.c` recreates symlinks), so the
   image matches the records for input-addressed and content-addressed
   closures alike. Covered by `tests/ab-image.nix` (the store tree
   preserves a symlink path in a real build) and the `overlay-nix-vm`
   suite (a symlink path ships, `nix path-info` resolves it).

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

Why runtime needs workarounds at all: nix's `LocalStore` constructor (nix
master as of 2026-10, `local-store.cc`) unconditionally creates its state
directories when ANY local store opens — `realStoreDir`, `realStoreDir/
.links`, and the state dirs under `nix/var/nix` — even when the store URL
says `read-only=true` (that flag only skips the remount step below). On an
appliance the store dir sits on a read-only squashFS mount, so two
constructor behaviours would otherwise fail every store open:

- `createDirs(realStoreDir/.links)` — a write onto the read-only squashFS.
- `makeStoreWritable()` (writable mode, as root) — attempts to remount the
  read-only store writable, which the squashFS/nspawn binds refuse.

The three workarounds, each mapped to the behaviour that forces it:

- **The image ships an empty `/nix/store/.links`** (a `.keep` placeholder
  via the partition contents). Every later `createDirs(.links)` becomes a
  no-op on an existing directory. GC may delete the placeholder file
  itself; the directory stays, and that is all the constructor needs.
- **The appliance's DB loader
  (`nixtache-lower-store-db-load.service`) runs `nix-store --load-db`
  inside `unshare -m --propagation private` with a tmpfs-upper OverlayFS
  over `/nix/store`**: the store stays readable (the loader's own binaries
  resolve), the directory-init lands in the discarded namespace, and the
  DB write to `/nix/var/nix` (on the writable root filesystem) persists.
  The namespace trick is load-bearing for the swap case — records must
  merge additively into the EXISTING database, so the DB cannot simply be
  rebuilt elsewhere and swapped in. (A unit-level
  `TemporaryFileSystem=/nix/store` cannot replace it: systemd would mask
  the unit script's own store path at exec time — status 203/EXEC.)
- **The runner container's clone seed reads the host DB through a writable
  scratch copy plus a `local?root=/&state=…&read-only=true` source URL**:
  sqlite cannot open the read-only bind-mounted DB file, so the seed
  copies it to `/run` first; the `read-only-local-store` experimental
  feature skips the remount attempt, and the `.links` entry shipped in the
  image satisfies the directory init.

These were re-verified against nix master in October 2026 — the
unconditional directory creation is still there, so none of the
workarounds can be dropped yet; re-check on every nix bump.

## Alternatives considered

- **Fixed CA (`ca = "fixed:r:sha256"` on the raw derivation)**: evaluates
  without any experimental feature, but nixpkgs exposes no switch producing
  it for regular packages — only the floating `__contentAddressed` spell
  (what `contentAddressedByDefault` sets) exists, so it is not a fleet-wide
  route.
- **Prebuilt `db.sqlite`**: merging a binary DB at runtime needs
  schema-aware tooling on the appliance; the records format is nix's own
  stable import format and merges additively by construction.

Test coverage: the dump, loader and store-tree wiring are pinned by
`checks.<system>.ab-image` (pure-eval; the store tree is also BUILT for
a tiny closure containing a symlink path), boot-time seeding and
symlink-faithful imaging by `vmTests.overlay-nix-vm`, the clone/overlay
consumption across a real swap by
`vmTests.runner-store-swap-{clone,overlay}-vm` — see
[`testing.md`](testing.md).

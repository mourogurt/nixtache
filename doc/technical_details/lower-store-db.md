# The lower store database (appliance images)

How the A/B appliance image ships a nix store database for its read-only
slot closure, and why the dump's hashes are computed the way they are.
OTA staging and installation live in [`ota.md`](../user_guide/ota.md); the
upper-generation lifecycle has one owner in
[`overlay-nix.md`](../user_guide/overlay-nix.md). Canonical requirements:
[`ab-ota`](../../openspec/specs/ab-ota/spec.md),
[`overlay-nix`](../../openspec/specs/overlay-nix/spec.md), and
[`runner`](../../openspec/specs/runner/spec.md). This document is for
contributors and owns the internals.

## The problem, stated in full

An appliance slot is a squashFS/erofs image: `/nix/store` is a read-only
mount populated with the system closure, and the image-based-appliance
profile disables nix entirely (`nix.enable = false` — appliances are not
rebuilt in place). Without the shipped dump and loader described below,
nothing creates the lower-state database that tells nix which paths exist
and what their contents' hashes are. Three consumer surfaces break on such
a store:

- **Runner container, clone mode** (`services.nixtache.runner.store.mode =
  "clone"`): the storage seeder enumerates "all valid paths" through the
  host's database — with no database the enumeration is empty, and the
  clone copies nothing.
- **Runner container, overlay mode**: a `lower-store=daemon` URL needs a
  system nix daemon, which a nix-less host does not have — the custom
  daemon's workers connect to their own socket and fork-loop.
- **Runtime installs through overlay-nix**: nix must realize the closure of
  whatever is installed — with no validity records for the lower store it
  cannot know that most of that closure already ships in the image, so it
  downloads everything into the upper layer (no delta installs).

The image therefore ships the closure's validity records (path, narHash,
narSize, deriver, references per store path) as a dump on the ESP. The
boot-time loader imports them into the selected lower-state, or directly into
`/nix/var/nix/db` without `overlay-nix`. On a nix-less appliance host the
runner container also disables its internal nix module, renders `nix.conf`
with the preserved settings plus `ca-derivations`, and ships the CLI
explicitly. Clone mode then enumerates a scratch copy of the real host DB.
Overlay mode binds the selected parent's frozen store and metadata read-only
under `/run/nixtache-runner-lower` for the singleton, or
`/run/nixtache-runner-lower/<logical-id>` for a named declaration. Without host
`overlay-nix`, that root is a plain read-only local lower. With host
`overlay-nix`, it exposes the selected parent's frozen files and the matching
`db`, `gcroots`, `profiles` and `temproots`. The parent's own consumer instead
uses that frozen lower plus its separate writable runtime continuation. A child
sees later parent runtime writes only after a generation rebase and child
restart; there is no live SQLite view or startup metadata-only copy. The
generation lifecycle is owned by [`overlay-nix.md`](../user_guide/overlay-nix.md).

The dedicated root is required because the custom daemon rebinds `/nix` to the
runner's merged relocated store: a lower rooted at `/nix` would read the
runner's own upper DB rather than the selected parent's frozen metadata. A
daemon lower is not an alternative on appliances because no host daemon exists,
and a write-capable parent daemon would not be a read-only lower boundary.

Clone mode is deliberately outside the upper-metaslot tree. Its single relocated
store at `<hostBackup>/nix` already contains a complete writable local store and
DB, not an OverlayFS upper with a separate lower/upper metadata role. A slot
swap seeds the new lower additively into that same store, preserving prior CI
outputs and avoiding a second multi-GB slot-owned copy. Overlay mode instead
places each runner upper and its upper-owned state in the physical slot's tree,
so target preparation and rollback select the host and runner layers together.

The rest of this document covers the internals: how the dump is generated,
how the store is imaged, and why the runtime workarounds exist.

## Lower-state and upper-state are different metadata roles

With `overlay-nix`, the host's `local-overlay` store opens two independent
metadata sets for the physical slot selected by the lower partition's GPT
`PARTUUID`:

- `upper-slots/<partuuid>/generations/<generation>/host/lower-state` holds
  the read-only records imported from that slot's lower dump. The loader
  tracks the dump's SHA-256, so replacing a lower image with the same version
  but different records still invalidates the old metadata.
- `.../host/state` holds the host runtime consumer's writable upper database,
  roots, profiles and temproots. Other physical nodes keep the same roles under
  `.../nodes/<physical-node>/state`. A frozen parent's state belongs to its
  immutable lower view; a runtime continuation has a distinct writable upper
  database. Runtime installations change only their own consumer's upper-owned
  state, never the physical lower-state or a sibling's database.

A child upper database may duplicate ancestor validity and reference records
needed by the local-store schema. Preparation refreshes and validates those
records together with visible files against the child's selected frozen parent;
they are not a shared writable ancestor database. Parent-first repair,
publication and rollback are documented once in
[`overlay-nix.md`](../user_guide/overlay-nix.md).

The stable `lower-state` link beside `upperDir` selects the physical lower
records; `/nix/var/nix/{db,gcroots,profiles,temproots}` selects the host
runtime consumer's upper-owned state. Equivalent links and read-only binds
select named runner and frozen-parent state before the lower loader, overlay
mounts and Nix daemons start. A plain reboot reselects the same generation,
while booting an older physical slot selects that slot's own preserved
lower-state and complete upper-state graph together; no dump is merged into
another slot's upper database.

Without `overlay-nix`, the appliance keeps its ordinary local-store layout
and the loader writes `/nix/var/nix/db` directly. In both layouts the ESP
artifact and its registration format are identical.

## Dump generation: registered records, content-true via content-addressing

The dump (`modules/ab-image/lower-store-db.nix`) is the toplevel closure's
REGISTERED validity records: `pkgs.closureInfo`'s `registration` output
(path, base16 narHash, narSize, deriver, references per path), one
derivation per toplevel. Trusting the daemon's DB records requires a
content-addressed evaluation, which the module asserts
(`nixpkgs.config.contentAddressedByDefault`; see below). Content addressing
resolves the record/content divergence below, while faithful imaging handles
the independent symlink constraint:

1. **Per-host realisations (why CA is required).** An input-addressed store path
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

2. **repart resolves top-level symlink copy sources (why faithful imaging is
   required for any store).** The image builder
   (systemd-repart, pinned 261.x) populates a partition from `CopyFiles=`
   lines, and it opens every copy source through path resolution that
   follows symlinks: a source that IS a symlink to a directory ships as
   that directory's content. nixpkgs' `image.repart` `storePaths` option
   emits one `CopyFiles=` line per closure path — so a closure path that is
   itself a symlink shipped as its target's content, contradicting its
   database record. The resulting clone-seed failure has this form:

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

One `nix-serve` cache can serve input-addressed and content-addressed paths
side by side: their store paths differ, so no conversion is needed. CA paths
enter the cache from CA-enabled builds; old input-addressed paths disappear
through ordinary retention as their references age out.

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
  selected lower-state on the writable root filesystem receives the records.
  The store URL's `state` parameter directs that write away from the upper
  database. (A unit-level `TemporaryFileSystem=/nix/store` cannot replace
  the namespace: systemd would mask the unit script's own store path at exec
  time — status 203/EXEC.)
- **The runner container's clone seed reads the host DB through a writable
  scratch copy plus a `local?root=/&state=…&read-only=true` source URL**:
  sqlite cannot open the read-only bind-mounted DB file, so the seed
  copies it to `/run` first; the `read-only-local-store` experimental
  feature skips the remount attempt, and the `.links` entry shipped in the
  image satisfies the directory init.

Nix's unconditional directory creation makes all three workarounds necessary;
re-check these constraints when changing Nix versions.

## Alternatives considered

- **Fixed CA (`ca = "fixed:r:sha256"` on the raw derivation)**: evaluates
  without any experimental feature, but nixpkgs exposes no switch producing
  it for regular packages — only the floating `__contentAddressed` spell
  (what `contentAddressedByDefault` sets) exists, so it is not a fleet-wide
  route.
- **Prebuilt `db.sqlite`**: merging a binary DB at runtime needs
  schema-aware tooling on the appliance; the records format is nix's own
  stable import format and merges additively by construction.

Historical design record:
[`lower-store-db`](../../openspec/changes/archive/2026-10-30-lower-store-db/design.md).

Test coverage: the dump, loader and store-tree wiring are pinned by
`checks.<system>.ab-image` (pure-eval; the store tree is also BUILT for
a tiny closure containing a symlink path), boot-time seeding and
symlink-faithful imaging by `vmTests.overlay-nix-vm`, the clone/overlay
consumption across a real swap by
`vmTests.runner-store-swap-{clone,overlay}-vm` — see
[`testing.md`](testing.md).

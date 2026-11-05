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
narSize, deriver, references per store path) as a dump on the ESP. With
`overlay-nix`, the boot-time loader imports the selected persistent
generation's exact `lower-db` into its lower-state. Without `overlay-nix`, or
for an entirely ephemeral overlay chain with no selected generation, the
loader instead uses the running version's ESP dump. The
[`overlay-nix` guide](../user_guide/overlay-nix.md#upper-metaslots-and-generations)
owns the generation-artifact and target-preparation contract. On a nix-less
appliance host the
runner container also disables its internal nix module, renders `nix.conf`
with the preserved settings, and ships the CLI explicitly. Clone mode then
enumerates a scratch copy of the real host DB. Overlay mode binds the selected
parent's frozen store and metadata read-only under
`/run/nixtache-runner-lower` for the singleton, or
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

## Paired snapshot generation

`modules/ab-image/slot-store-snapshot.nix` builds one derivation with two
subpaths in its result:

- `root/nix/store/` contains every toplevel-closure path under its original
  store basename;
- `lower-db` contains the standard `nix-store --load-db` validity-record dump.

The repart store partition and the ESP dump both consume subpaths of this one
result. They therefore cannot be substituted or selected from different
build histories: even when an input-addressed source path has multiple
realisations, the image's bytes and records always come from the same
immutable snapshot. The dump has no independent `closureInfo`-backed build.

Without that pairing, an input-addressed store path can be copied from one
realisation while its independently generated dump carries another
realisation's NAR hash. On the runner clone surface, the storage seeder opens
the appliance's lower store and runs `nix copy --all`; Nix serializes the
shipped path, finds that its bytes do not match the recorded hash and aborts
with `hash mismatch importing path`. Seeding then fails and the runner's
custom store cannot start. Taking both image inputs from one snapshot
prevents cross-artifact realisation mixing, and staged-byte registration
makes each shipped record match the content inside that snapshot.

The derivation uses `__structuredAttrs` and `exportReferencesGraph` to obtain
the source closure's path identities and direct references. It stages regular
paths with reflink-capable copying and recreates a top-level symlink with its
original target text. Ownership remains the image builder's responsibility;
the source store's modes and timestamps are otherwise preserved during
staging.

### Registration and validation

The builder opens the staged tree as
`local?root=$out/root&state=<temporary-state>`, with writable scratch state
outside the output. It feeds each exported path, an empty deriver and its
direct references to `nix-store --register-validity` **without**
`--hash-given`. Nix consequently computes each NAR hash and size from the
staged filesystem object, including the symlink object itself. It does not
copy the source store's NAR metadata. `nix-store --dump-db` then exports the
new records to `lower-db`; the temporary SQLite database, locks, profiles and
roots never enter the artifact. These legacy local-store operations need no
daemon, network, host database writes or `ca-derivations` support.

Registration computes content metadata but does not rediscover references.
The reference graph therefore crosses a trust boundary from the source Nix
store: ordinary Nix build and substitution machinery must have supplied
coherent source metadata. Before the snapshot succeeds, the builder verifies
that the staged, dumped and queried-reference-closure path sets all equal the
exported closure, and runs `nix-store --verify-path` for every path. This
catches missing or overwritten staging entries and incomplete reference
closures; it is not a NAR reference scanner or a defence against a corrupt
source database. Artifact signing authenticates the graph and bytes together,
and hashing does not establish provenance.

Unchanged toplevels and snapshot recipes reuse the complete cached snapshot.
A changed input stages and NAR-hashes the closure once; repart, ESP assembly
and downstream consumers do not repeat that work. An uncached build pays a
full closure read/hash, trading that I/O for an ordinary input-addressed build
without a CA world rebuild. Later squashFS/erofs compression does not affect
NAR identity.

### Symlink-faithful imaging

systemd-repart resolves every top-level `CopyFiles=` source. A store path that
is itself a symlink would therefore ship as its target's contents if passed
as an individual source, contradicting its record. The partition instead
receives the snapshot's `root/nix/store` as one source. Repart resolves that
tree once and preserves the types of entries inside it, including absolute or
relative symlink targets. The snapshot's staged-byte registration makes the
record describe that same symlink object, so standard Nix path queries and
closure copies verify without content-addressed realisations.

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

- **Custom NAR serializer or content-derived path renaming**: Nix's scratch
  registration already computes the required metadata from the staged bytes;
  duplicating its serialization or changing store identities would add a
  fragile compatibility surface without improving snapshot coherence.
- **Prebuilt `db.sqlite`**: merging a binary DB at runtime needs
  schema-aware tooling on the appliance; the records format is nix's own
  stable import format and merges additively by construction.

Historical design record:
[`lower-store-db`](../../openspec/changes/archive/2026-10-30-lower-store-db/design.md).

Test coverage: [`testing.md`](testing.md) owns the real-store fixture and KVM
acceptance inventory for the snapshot, loader and runner store consumers.

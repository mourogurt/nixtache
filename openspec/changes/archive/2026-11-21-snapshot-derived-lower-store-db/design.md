# Design

## Context

See `proposal.md` for motivation and `specs/` for the observable contracts.

On `main`, `modules/ab-image/store-tree.nix` materialises the toplevel closure for `repart`, while `lower-store-db.nix` independently copies `pkgs.closureInfo`'s registered records. A CA evaluation makes those records content-true, but it also makes every appliance build depend on experimental floating-CA behavior. Input addressing alone is not a safe reason to combine independently built or substituted tree and dump artifacts: the same input-addressed source path can have different realisations, while the two artifacts can be selected from different cache/build histories.

Nix already exposes the required operation without CA. `nix-store --register-validity` without `--hash-given` accepts path/deriver/reference records and computes NAR hash and size from the filesystem objects present in a local store. A scratch `local?root=...` store can therefore register the exact staged image tree and export coherent records through `nix-store --dump-db`.

## Goals / Non-Goals

**Goals:**

- Produce the slot's store tree and lower database from one immutable, cacheable build artifact.
- Recompute NAR hash and size with Nix itself from the exact bytes supplied to the image builder.
- Support ordinary input-addressed nixpkgs evaluations without CA-only daemon, cache or builder configuration.
- Preserve the existing runtime dump format, complete reference graph, top-level symlink fidelity and unchanged-snapshot cache reuse.
- Exercise the same downstream copy and runtime paths that previously exposed record/content mismatches.

**Non-Goals:**

- No content-derived store-path renaming, post-build path rewriting, custom NAR serializer or replacement binary-cache protocol.
- No fs-verity/dm-verity integration; filesystem integrity mechanisms do not generate Nix validity records.
- No conversion or migration of deployed CA appliances, mixed CA/IA rollback guarantees or preservation of CA upper state.
- No assumption that hashing proves provenance or protects against a malicious image builder; artifact signing remains the authentication boundary.
- No runtime rehashing of the lower closure on every boot.
- No implementation or integration with `slot-scoped-overlay-uppers` in this change; that backport is deliberately later work.

## Decisions

### D1 — One derivation owns the paired store snapshot

Introduce an internal slot-store snapshot derivation with this logical output layout:

```text
$out/
  root/nix/store/<closure entries>   # the single repart CopyFiles source
  lower-db                           # the single ESP dump source
```

The derivation uses `__structuredAttrs` and `exportReferencesGraph` for the toplevel closure. During its build it copies every regular closure path into `root/nix/store` and recreates a top-level symlink path with its original target text. Modes and relevant metadata are canonicalised by Nix during registration; ownership remains the image builder's responsibility as it is today.

Both downstream image inputs MUST reference subpaths of this same output. There must be no independent `closureInfo`-backed dump derivation or separately substitutable store-tree derivation in the image path. If the paired snapshot itself is substituted, its tree and dump still originate from one builder execution and one source-store realisation set.

Alternative considered: keeping separate tree and dump derivations and merely recomputing hashes in the latter still permits independently selected IA artifact histories and retains an unnecessary cache-coherence hazard.

### D2 — Nix registers the staged tree in a scratch local store

The snapshot builder creates a temporary state directory outside `$out`, opens the staged tree as:

```text
local?root=$out/root&state=<temporary-state>
```

and supplies hashless `exportReferencesGraph` records to `nix-store --register-validity`. The input for each path contains its logical `/nix/store` path, an empty deriver (matching the existing `closureInfo` dump) and its direct references. Because `--hash-given` is absent, Nix canonicalises each staged path and computes its NAR hash and size from the staged filesystem object, including the symlink object itself where applicable.

The builder then runs `nix-store --dump-db` on that scratch store and writes the result to `$out/lower-db`. The temporary SQLite database, locks, profiles and roots never enter the image artifact. The runtime loader continues to consume this standard dump with `nix-store --load-db`; its carrier, sysupdate transfer and checksum interfaces do not change.

These operations use the legacy local-store interface and do not enable `ca-derivations`. No daemon, network access, IFD or host Nix database write is involved.

Alternative considered: invoking `nix hash path` and formatting records directly would still require a separate size pass and more custom record assembly. Scratch registration lets Nix compute and export the complete validity record through its native image/chroot mechanism.

### D3 — Reference topology comes from Nix metadata, with closure validation

`register-validity` computes NAR metadata but does not rescan references. The direct-reference set therefore comes from the source Nix store's exported reference graph, just as it does for the existing `closureInfo` approach. The builder must not invent or filter references.

Before the snapshot can succeed:

- every exported closure path must be staged exactly once under its original basename;
- every direct reference must name a path registered in the same scratch store;
- the dumped path set must equal the exported toplevel closure set;
- querying the toplevel's reference closure in the scratch store must return exactly that set;
- `nix-store --verify-path` over every staged path must succeed against the newly registered records.

This establishes database/schema coherence and NAR content coherence under the existing trusted-source-store model. It does not claim to recover a correct reference graph from an arbitrarily corrupted source database. Nix's normal build/substitution path remains responsible for producing coherent source metadata, and the signed image bundle remains responsible for authenticating the resulting graph and bytes together.

Alternative considered: implementing a NAR reference scanner would add a fragile compatibility surface and a stronger adversarial guarantee that the existing CA image pipeline does not provide.

### D4 — Input addressing becomes the supported image and runtime baseline

Remove the AB image's `contentAddressedByDefault` assertion and replace the shared CA package-set imports and package overrides in `flake.nix` and test fixtures with ordinary package-set imports. New appliance images and all affected tests must evaluate with input-addressed derivations.

Remove `ca-derivations` from nixtache-rendered runner and overlay Nix feature sets and from Nix invocations where it was needed only to read or copy the former CA appliance closure. `nix-command`, `flakes`, `local-overlay-store` and `read-only-local-store` remain independent requirements where already used. Runner cache backend selection is otherwise unchanged; changing cache implementations is not part of this design.

Do not add a module option that selects IA versus CA. The supported contract is snapshot-derived records with IA coverage, not a second untested addressing mode. A consumer's own experimental CA evaluation is outside nixtache's support guarantee.

Alternative considered: leaving CA enabled everywhere as a compatibility precaution would preserve configuration and specification surface motivated solely by a closure type that no longer exists. With no deployed CA systems, there is no compatibility reason to retain it.

### D5 — Snapshot caching replaces registered-dump caching

The paired snapshot remains an ordinary Nix derivation output keyed by the toplevel and snapshot recipe. Unchanged inputs reuse the complete artifact; changed inputs stage and hash the closure once in a new artifact. Tree construction and NAR hashing are therefore not repeated independently by `repart`, the ESP image or downstream consumers.

This trades a full NAR read/hash during each previously uncached snapshot build for removal of the CA world rebuild and its operational constraints. Compression performed later by squashfs/erofs is unchanged and is not part of NAR identity.

### D6 — Verification proves artifact pairing and downstream behavior

Focused build checks must use real Nix stores rather than only inspecting generated shell text:

1. Build a small IA closure containing regular directories/files and a top-level symlink store path; load the emitted dump against the emitted tree and verify every path and reference closure.
2. Deliberately alter a staged fixture before scratch registration and assert that the emitted NAR hash follows the altered staged content rather than the source registration. This is a test-only mismatch oracle, not a production mutation hook.
3. Copy the complete closure from the snapshot-backed store into a second scratch store with ordinary Nix copy operations and signature checking disabled only for the local fixture. Every NAR hash must verify, covering the runner clone failure mode.
4. Assert in pure evaluation that the repart store source and ESP dump source are subpaths of the same snapshot output and that ordinary IA evaluation contains no CA assertion.
5. Run the affected AB, overlay and runner pure/KVM scenarios with CA derivation support disabled, including lower-delta installation, runtime profile installation, clone and overlay runner seeding, OTA swap and rollback.

The existing full-closure KVM tests remain the acceptance boundary; a focused scratch-store test does not replace them.

## Risks / Trade-offs

- [Full NAR hashing adds build-time I/O] → Perform it once inside the paired snapshot, reuse that output for unchanged inputs and retain reflink-capable copying.
- [A cached IA snapshot can contain bytes different from another realisation of the same source path] → Treat the snapshot as the immutable authority; its internal tree and DB are coherent, and image assembly cannot mix it with another dump or tree.
- [Source reference metadata can be stale if the source store itself is corrupt] → Require a coherent Nix source store, validate the complete registered reference closure and fail the snapshot build instead of silently dropping references.
- [IA path names are not self-certifying] → Preserve sysupdate manifest signing and existing binary-cache signature policy; do not represent snapshot-derived IA paths as CA paths.
- [Scratch local-store setup may encounter Nix's directory creation and canonicalisation behavior] → Use a writable staged root with separate temporary state, retain the required `.links` handling and pin the exact behavior with real-store tests.
- [Removing CA flags exposes assumptions unrelated to image hashing] → Run runner, overlay, copy and OTA tests with CA support disabled rather than merely removing configuration text.

## Migration Plan

1. Implement the paired snapshot and focused real-store checks on `main`, without changing the runtime dump carrier or consumer options.
2. Switch appliance test package sets and rendered Nix environments to the IA baseline, then pass the affected pure and KVM acceptance suites with CA support disabled.
3. Update maintained documentation to describe the snapshot-derived trust and caching model. Consumers building new images use their ordinary input-addressed nixpkgs import and need no CA migration action.
4. Do not upgrade a deployed CA appliance as part of this change; none exist in the supported deployment set. No on-target data conversion is required.
5. After this change is accepted on `main`, integrate it into `slot-scoped-overlay-uppers` as a separate backport and reconcile that change's CA/IFD assumptions there rather than expanding this change's scope.

Rollback before deployment is a normal revert to the previous image-build revision. There is no persistent database migration to reverse on a target.

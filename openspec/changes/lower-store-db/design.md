# Design

## Context

Evidence gathered in `server-ab-migration-prep` (see its design.md, D3):

- On a real appliance image, `container@runner.service` failed to start
  (nixpkgs dfce2e0 bind-ros host `/nix/var/nix/db` + `daemon-socket`
  unconditionally) — fixed there by a tmpfiles guarantee.
- With the container up, overlay mode's custom daemon fork-loops:
  `lower-store=daemon` points at a system daemon that cannot exist on a
  nix-less host (the RO-bound socket dir cannot create a socket), so the
  daemon's workers reconnect to their own socket.
- Clone mode seeds via `nix copy --all` from a scratch copy of the host DB —
  empty on appliances, so nothing is copied.
- The validity-record DB seed format (5 lines per path: path, bare-base16
  narHash, narSize, deriver-or-empty, refs) is already proven in
  `tests/overlay-nix-ota-invalid-vm.nix`, which hand-builds records from
  `nix path-info --json` and loads them with `nix-store --load-db`.

## Goals / Non-Goals

**Goals:**

- The appliance image ships a store DB covering the slot closure; the lower
  store is a first-class readable store on every boot.
- Runner container works on nix-less appliance hosts in both store modes.
- overlay-nix installs become delta against a valid lower (world A shipped).
- The lifecycle interplay (swap re-seed, wipe re-seed, reconcile healing
  stale records) is specified and pinned.

**Non-Goals:**

- No change to the slot image format, partitioning or the sysupdate flow.
- No upper-layer GC policy change beyond what world A requires.
- Not backfilling DBs onto already-deployed appliances (a wipe/reinstall
  concern; the OTA update that first ships the DB seeds it at boot).

## Decisions

### D1 — DB content: the closure's registered records, content-true via content-addressing

The dump is `pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; }`
— its `registration` output is the `nix-store --load-db`-compatible records
format (path, base16 narHash, narSize, deriver, references per path), one
derivation per toplevel, so image rebuilds with unchanged closures reuse it.
No custom hashing: trusting DB-inherited records is justified by the fleet
running content-addressed (the decision below), which makes those records
content-true by construction.

**Why DB-inherited records are only safe under CA (the decisive
implementation finding).** The first version used exactly this
`closureInfo` source, and on the real runner the clone seed died in an
infinite retry:

```
error: hash mismatch importing path '/nix/store/azs59nr9...-nix-2.34.8-man';
       specified: sha256:14rh8r1k8k9...   (the DB record — a 184-byte symlink)
       got:       sha256:0c6z1cjk5yv...   (the shipped content — 476 KB of man pages)
```

Two independent failure modes, with different fixes:

1. **Per-host realisations.** An input-addressed store path legitimately has
   *different* realisations on different hosts (substitution churn, older
   realisations accumulated in a long-lived CI store, recipes whose output
   changed shape across nixpkgs revisions). The daemon's DB records what
   *this* host believes; the image ships whatever `repart CopyFiles` finds
   in the store — and the two diverge silently. `nix copy` re-verifies every
   copied path against the source DB's recorded narHash and hard-fails on
   any divergence — a landmine exactly under the production use case (the
   runner's clone). **CA eliminates this class**: under `ca:fixed:r:` the
   path hash IS the content hash — a build computes content→path,
   substitution verifies content against the narinfo, so the DB cannot lie
   about content.
2. **repart resolves top-level symlinks when imaging.** A store path that
   IS a symlink to another store path ships as a real directory with the
   target's content — the shipped bytes contradict the path's record (the
   azs59nr9 mismatch above is this class). **CA does not fix this**: it is
   imaging behaviour, not hashing. The interim fix — rewriting the record
   from the resolved path's content — is *invalid under CA* (a record whose
   narHash contradicts the path's content-addressed hash fails `nix copy`
   just as hard). Mitigation: a **build-time guard** — the image build
   fails, listing any closure path that is a top-level symlink (rare; the
   offender gets repackaged). A silent runtime landmine becomes a loud
   build error.

**Decision (revised after review): the OTA + overlay-nix fleet runs
content-addressed.** The original design rejected CA as a module contract
(full world rebuild, the shared cache stops matching) and shipped a custom
per-path content-hashing dumper (python + `nix-store --dump`) instead.
That rationale is moot on the deployment side now: the fleet's cache/DB is
already migrating to `ca:fixed:r:` realisations, so the rebuild cost is
being paid regardless — while the custom dumper remains a fragile
compatibility surface (NAR serialization in python, symlink special-casing)
that CA makes redundant. Consequences:

- The appliance image evaluation MUST be content-addressed by default
  (`config.contentAddressedByDefault = true` on the nixpkgs import — the
  wiki-documented route). A module cannot silently flip a flake consumer's
  pkgs, so `ab-image` **asserts** `pkgs.config.contentAddressedByDefault`
  and fails the image build with fix guidance when it is off. Resolved at
  implementation: there is NO `content-addressed-by-default` nix.conf
  setting (nix 2.34.8), and the evaluator's `ca-derivations` gate consults
  the daemon-side config — client-side overrides (flags, `NIX_CONFIG`,
  user nix.conf) are ignored once the new CLI connects to a store
  (NixOS/nix#9090). CA therefore also requires the feature in the SYSTEM
  nix.conf of every evaluating machine; the modules ship it in the runner
  container's rendered conf and the overlay appliance's `nix.settings`,
  and the assertion message + docs call out the system-conf requirement
  (details: doc/technical_details/lower-store-db.md).
- Every nix that *evaluates or builds* the fleet's closure needs
  `experimental-features = ca-derivations`: the runner container's
  module-rendered nix.conf, the overlay appliance's runtime daemon
  (profile installs evaluate derivations), and the build-side CI
  evaluation. Mere substitution or `nix copy` of CA paths does not need
  the feature; the boot loader's `nix-store --load-db` does not either.
- **One nix-serve serves both IA and CA paths.** A binary cache is a set
  of NARs+narinfos keyed by store path; CA and IA realisations of a
  package are simply different paths coexisting in one store/DB, and
  nix-serve has no CA awareness (signing, `require-sigs` unchanged).
  Transition caveats: no IA→CA conversion (the cache holds both kinds
  until IA references age out of the retain policy), and CA paths only
  enter it from CA-enabled builds.
- The custom dumper (`lower-store-db-dump.py`) and its
  `__structuredAttrs`/`exportReferencesGraph` machinery are deleted; the
  dump becomes `closureInfo.registration` plus the symlink guard above.

Alternative considered: shipping a prebuilt `db.sqlite` — rejected as the
primary mechanism because merging a binary DB at runtime needs
schema-aware tooling on the appliance; the records format is nix's own
stable import format and merges additively by construction.

Constraint found at implementation time: the dump derivation references the
toplevel, so the toplevel must NOT reference the dump back — shipping via
`environment.etc` or as a toplevel-referenced store path is a derivation
cycle. The dump therefore ships as a fixed-path artifact of the image (see
D2). A second carrier constraint: NOT inside `/nix/store` — the
local-overlay store's GC scans the merged store dir and hard-fails on any
non-store-path entry ("too short to be a valid store path"; GC skips only
`.`, `..` and `.links` by name).

### D2 — Loading: boot-time oneshot, load-when-missing-or-stale

The dump lives on the ESP at a versioned path
(`/EFI/nixtache/<imageId>_<version>.lower-db`) and travels across updates via
a dedicated sysupdate transfer (`15-lower-db`, InstancesMax=2, so the old
slot's dump is vacuumed together with its UKI). The ESP carrier is the result
of two constraints found at implementation time:

- NOT `environment.etc` / a toplevel-referenced store path: the dump covers
  the toplevel closure, so a toplevel→dump reference is a derivation cycle.
- NOT inside `/nix/store`: the local-overlay store's GC scans the merged
  store dir and hard-fails on any non-store-path entry ("too short to be a
  valid store path").

The loader's dump path and the image version are baked per-slot, so after a
swap the running unit reads the NEW slot's dump from the ESP. A oneshot at
boot loads it into `/nix/var/nix/db` with `nix-store --load-db` when:

- the DB file is absent (first boot, or after `upperOnUpdate = "wipe"`
  deleted it), or
- the recorded image-version marker (`/var/lib/nixtache/lower-db-version`)
  differs from the running `system.image.version` (a swap happened — the new
  slot's records merge in additively).

Stale old-slot records are not deleted (load-db is additive); they are
exactly the dangling entries the coherence machinery already detects
(`nix-store --verify`) and the reconcile pass heals. The loader needs a nix
binary on a nix-less appliance: ship `pkgs.nix` in the image (the "no nix"
appliance profile stance is about not rebuilding the system; a binary used
by a oneshot is fine — and overlay-nix consumers re-enable nix anyway). The
unit runs its loader inside `unshare -m --propagation private` with a
tmpfs-upper OverlayFS over `/nix/store`: `nix-store --load-db` initialises
the store dir (creates `.links`), which fails on the RO squashFS lower — the
namespace-private tmpfs upper satisfies the init and is discarded at exit.
(A unit-level `TemporaryFileSystem=/nix/store` cannot be used: it masks the
unit script's own store path at exec time — status 203/EXEC.)

### D3 — Runner container wiring on nix-less hosts

When the HOST has `nix.enable = false`, the runner module's container
config switches to appliance mode:

- `nix.enable = false` inside the container (plus `nix.gc.automatic =
  false`, `nix.optimise.automatic = false` — nixpkgs asserts those need
  nix) → the standalone branches in `store.nix` activate (clone: no
  `nix-daemon.service` requirement, scratch-DB copy of the now-real host DB;
  overlay: no storage oneshot).
- `nix.conf` is rendered by the module directly (`environment.etc."nix/nix.conf"`,
  same settings content — the nix module no longer writes it) so CI keeps
  `system-features`/substituters/trusted-users, and it enables the
  `ca-derivations` experimental feature (the fleet's closure is
  content-addressed — see D1).
- The nix CLI is added to the container's `systemPackages` explicitly.
- The overlay store URL uses `lower-store=local` (not `daemon`): the RO-bound
  host DB is real and readable, so a local lower opens and serves lower
  validity; `daemon` self-references when no system daemon exists (the
  fork-loop evidence from the swap suite).

### D4 — overlay-nix: world A becomes the shipped reality

With the lower DB present, overlay installs fetch only paths missing from
the merged store (delta), and upper paths whose references lived only in the
old lower genuinely dangle after a swap. Consequences:

- The `overlay-nix` spec's persistence requirements are reworked from
  "upper survives by closure completeness" (world B) to "upper is a delta;
  swaps need a lifecycle policy" (world A). The existing
  `upperOnUpdate = "none"` default becomes hazardous for ad-hoc installs.
  **Decision (was flagged for review): `"none"` is removed from the enum
  entirely and the default becomes `"wipe"`.** The state space is OTA
  on/off × overlay on/off; when both are on, the only question is
  wipe-vs-reconcile — a carried upper deterministically produces dangling
  references, so a no-op value has no meaningful behaviour left. `"wipe"`
  is the default (deterministic, substituter-independent — the only policy
  safe with zero prerequisites); `"reconcile"` stays opt-in for hosts with
  a binary cache (the reference server sets it explicitly).
  Configurations setting `"none"` fail evaluation with the enum error
  naming the two valid values.
- The `overlay-nix-ota-invalid-vm` suite's manual DB seeding is retired —
  the shipped appliance IS world A now. The suite's hazard/mitigation legs
  keep their assertions but lose the seed construct; a new leg pins that a
  lower path's validity is present out of the box (no seed).

### D5 — The swap suite (`runner-store-swap-vm`) completes and joins the matrix

Both modes green on a real appliance: clone (additive re-clone incl. the new
lower's content) and overlay (coherent merged view, builds keep working).
The suite joins the `vmtests.yml` full matrix.

## Risks / Trade-offs

- [Image size: shipping `pkgs.nix` + the dump adds tens of MB to the slot]
  → measured by the compression suite's neighbours; acceptable for the
  runner-host use case; reconsider if minimal appliances care.
- [Additive loads accumulate stale lower records across many swaps] →
  bounded by slot count (InstancesMax=2) and healed by verify/reconcile;
  documented.
- [Schema drift between the build-time nix and the runtime nix] → the
  records format is stable across nix 2.x (`load-db` is the archival
  format); pinned by a boot-time VM assertion that a lower path resolves
  `nix path-info`.
- [World-A transition breaks existing world-B assumptions in user configs]
  → the spec rework calls it out; the lifecycle policy guide covers the
  recommended settings per environment.
- [CA transition: IA and CA realisations coexist in the fleet cache] →
  paths never collide (different hashes); disk grows until IA references
  age out of the retain policy — no correctness impact (one nix-serve
  serves both).
- [`ca-derivations` remains an experimental nix feature] → the pinned nix
  is the contract; re-verify the fleet's CA assumptions on every nix bump
  (the records format itself is stable).
- [Non-deterministic packages fail CA builds loudly instead of diverging
  silently] → surfaced as CI build errors in the fleet, fixed per package
  (the docs/timestamps class); preferable to a silent runtime mismatch.

## Migration Plan

Existing appliances pick the DB up with the first OTA image that ships it
(the loader seeds at boot; no operator action). Runner hosts flip to the new
container wiring with the same update. The fleet's cache is already
migrating to `ca:fixed:r:` realisations: the first content-addressed image
that ships the DB seeds it at boot as usual, and IA-built slots keep
working off their IA cache entries during the transition. One breaking
change: `upperOnUpdate`
loses its `"none"` value and defaults to `"wipe"`. Configurations that never
set the option will wipe their upper layer on the first update after this
lands; configurations setting `"none"` explicitly fail evaluation (the enum
error names `"wipe"`/`"reconcile"`). Operators relying on the carried upper
MUST move to `"reconcile"` (with a substituter configured) before deploying.
The release notes and the overlay-nix user guide call this out. `server-ab-migration-prep` group 3 resumes once this lands (its
runner-store-swap suite then joins the matrix).

## Open Questions

(none — `upperOnUpdate` is decided in D4 (`"none"` removed, `"wipe"` the
default); the CA pivot is decided in D1, with one implementation-time check
noted there: whether the pinned nix also exposes a
`content-addressed-by-default` nix.conf setting)

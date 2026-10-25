# Design

## Context

See proposal.md — Why. Architecture recap that shapes the approach: nix-serve
(Perl/Starman, 5 prefork workers, one request per worker) runs inside the
nixos-container and generates every NAR on the fly; the host nginx proxies
`https://cache.domain/` to `localhost:<port>` with default 60s proxy timeouts
and no caching (`modules/runner/cache.nix`). The same vhost also serves the
ab-image staging store from a static root (`modules/runner/ab.nix`). The
store lives on a ZFS pool on a single HDD; the host root (where nginx cache
paths conventionally live) is NVMe. `nix-daemon-custom` runs with
`KillMode = "process"` (`modules/runner/store.nix`), which leaks per-connection
daemon workers on every unit stop.

## Goals / Non-Goals

**Goals:**

- Clients keep downloading previously-served NARs through container restarts
  and backend stalls (502/504 bursts observed on the reference host).
- N concurrent fetches of the same NAR cost one upstream `dump-path`.
- No leaked nix-daemon worker processes after `nix-daemon-custom` stops.
- New behaviour is on by default, opt-out via one option.

**Non-Goals:**

- Replacing nix-serve (harmonia/attic/static file tree). A static file-based
  cache remains a possible future direction; it changes the *write* path
  (push step), the narinfo freshness story and the GC interplay, and is not
  needed for the observed failure modes.
- Serving cold (never-cached) paths while the backend is down — impossible
  at the edge; the spec states this explicitly.
- Scrub scheduling or ZFS tuning on the host (documented as operational
  guidance only).

## Decisions

### D1: nginx `proxy_cache` shield on the cache vhost (adopted)

Add a dedicated cache zone (e.g. `proxy_cache_path
/var/cache/nginx/nixtache-bincache`, `levels=1:2`, `keys_zone=bincache:10m`,
configurable `max_size`, `inactive` eviction) and enable it only on
`locations."/"` of the cache vhost — the ab staging location
(`ab.nix`) has its own static `root` and must stay untouched.

Cache policy:

- `/nar/*` responses (200): long-lived (NARs are immutable) — e.g.
  `proxy_cache_valid 200 30d`.
- narinfo 200: cached, but with a moderate TTL (order of hours) so the retain
  GC story (paths ageing out) does not leave narinfos pointing at deleted
  NARs forever; `proxy_cache_use_stale` still bridges upstream failures.
- narinfo 404: short negative TTL (e.g. 1m) — keeps newly pushed paths
  visible promptly (spec: negative-answer freshness).
- `proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504`.
- `proxy_cache_lock on` with a generous `proxy_cache_lock_timeout` — the
  coalescing that collapses N-machine update storms into one `dump-path`.
- Raise `proxy_read_timeout` on this location (order of minutes): a slow dump
  under IO pressure should complete and *fill* the cache instead of timing
  out and poisoning nothing.

Placement on the host root filesystem (NVMe on the reference host) moves hot
NAR reads off the HDD ZFS pool entirely.

**Alternative considered:** static file-based binary cache tree served by
nginx directly (like the ab staging store). Rejected for this change: it
replaces the on-demand *read* path with an explicit *push* path (every build
result must be `nix copy --to file://...`ed), duplicates GC policy onto the
tree, and orphan narinfos appear on push failures. The proxy_cache shield
solves the observed 502/504 modes without any of that. Can be revisited —
the two are not mutually exclusive.

### D2: Option surface

`services.nixtache.runner.cache.nginxCache = { enable = true; maxSize = "10g"; }`
(the zone directory is fixed at `/var/cache/nginx/nixtache-bincache` — the
nixpkgs `proxyCachePath` submodule derives the path from the zone name and
exposes no `path` option). `enable = false` restores the exact current
plain-proxy config. All options get `description` (CI-enforced) and tests.

### D3: `KillMode` leak fix

Change `nix-daemon-custom` from `KillMode = "process"` to
`KillMode = "mixed"`: main process gets SIGTERM; remaining per-connection
workers get SIGKILL after `TimeoutStopSec`. Rationale: the daemon's
per-connection children are the leakers (`Unit process ... remains running
after unit stopped` observed chronically); "process" was leaving them
unmanaged. Trade-off: in-flight dump/CI connections die on restart — nix
clients retry, and restarts are rare; the alternative ("control-group"
SIGTERM to all) gives workers a graceful phase the daemon does not need.

### D4: Scheduling priority for nix-serve

Give the in-container nix-serve unit explicit favourable scheduling
(`Nice = -5`, best-effort IO class with top priority), leaving the
forgejo-runner units at defaults. Modest by design: it tips contention
toward interactive cache fetches without risking CI starvation, and stays
honest on hosts where the container has its own cgroup weights.

### D5: Docs

One technical-details document for the cache-availability machinery (nginx
edge cache policy, why not a static tree, KillMode semantics, the
ZFS-scrub-on-single-HDD operational note with the full problem statement per
AGENTS.md rule 6); user-guide touch where the cache is introduced; README
map line if the cache description changes. All linked to
`openspec/specs/runner-cache/spec.md`.

## Risks / Trade-offs

- [Stale narinfo outliving a GC'd NAR] → moderate positive narinfo TTL +
  `proxy_cache_use_stale`; worst case is a fetch failure the client already
  tolerates (falls back / retries), same as today's behaviour.
- [Cache zone eating host root disk] → `max_size` cap + `inactive` eviction;
  the zone holds only hot NARs, not the whole store.
- [`proxy_cache_lock_timeout` expiry duplicates one upstream fetch under very
  slow dumps] → harmless (two dump-paths instead of N); timeout sized above
  typical large-NAR dump time.
- [KillMode = "mixed" kills in-flight CI daemon connections on restart] →
  restarts coincide with switches; nix retries substituter fetches; build
  failures surface noisily rather than silently corrupting anything.
- [Negative narinfo caching briefly hides a just-pushed path] → 404 TTL
  ~1 minute; documented.

## Migration Plan

No breaking changes: `nginxCache.enable` defaults to true; consumers wanting
the old behaviour set it to false. On first deploy, nginx creates the cache
directory itself; no state migration. Rollback: set `nginxCache.enable =
false` and rebuild — the vhost returns to plain proxying.

## Open Questions

- Exact default TTLs/sizes (narinfo positive TTL, `max_size`, lock timeouts)
  are tuned against the reference host's observed NAR sizes during
  implementation; they do not change the spec.

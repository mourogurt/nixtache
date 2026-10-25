# Binary cache availability

The runner module's binary cache (`cache.domain`, nix-serve inside the
container fronted by a host nginx vhost — see
[`architecture.md`](architecture.md)) has two main availability risks. This
document states each failure fully, then describes the machinery that absorbs
it. Normative requirements live in
[`openspec/specs/runner-cache/spec.md`](../../openspec/specs/runner-cache/spec.md).

## Failure modes

**Backend restart windows.** A host switch that changes and restarts the
runner container also stops nix-serve while `nix-daemon-custom` re-establishes
the store view. Clients updating during that window can receive 502 responses
from nginx because the upstream refuses connections. Container definition
changes restart the container by default; a consumer can override that
behavior through the NixOS container options.

**Worker saturation under IO pressure.** With the default `cache.package`,
nix-serve (Perl/Starman, 5 prefork workers, one request per worker) generates
NARs on demand with `nix dump-path` and streams them uncompressed. Heavy IO —
for example, a scrub on a single-HDD ZFS pool — can keep every worker busy.
New connections then overflow the listen backlog or exceed an nginx proxy
timeout, producing 502/504 responses without a crash or restart in the
journal.

## The nginx edge cache (default on)

`cache.nginxCache.enable = true` (default) adds a `proxy_cache` zone
(`nixtache-bincache`, at `/var/cache/nginx/nixtache-bincache` — the host
root filesystem, deliberately not the store disk) on the cache vhost:

- `/nar/*`: NARs are immutable → 30d positive TTL. `proxy_cache_lock`
  coalesces concurrent cache misses for the same NAR, reducing duplicate
  upstream dumps. Lock age and `proxy_cache_lock_timeout = 300s` bound that
  coalescing; a sufficiently slow fill can still result in multiple upstream
  requests.
- narinfo (`/`): 6h positive TTL (bounded so retain-GC'd paths don't leave
  stale narinfos forever), 1m negative TTL so freshly pushed paths become
  visible promptly.
- `proxy_cache_use_stale error timeout updating http_500 http_502
  http_503 http_504`: content still resident in the cache can be served
  through backend restarts, saturation and 5xx instead of failing the client.
- `proxy_read_timeout 300s`: allows up to 300s of inactivity between successive
  upstream reads, giving slow dumps more time to complete and fill the cache.
  It is not a guarantee that every dump finishes.

The zone defaults to `cache.nginxCache.maxSize = "10g"` and `inactive = 30d`.
Capacity pressure can evict entries earlier, independently of their freshness
TTL. Cold or evicted paths still require a live backend — the edge cache
cannot invent content. `cache.nginxCache.enable = false` restores the plain
proxy-pass vhost.

**Rejected alternative:** a static file-based binary cache tree served by
nginx directly (the pattern the ab-image staging store uses). It replaces
the on-demand read path with an explicit push path (every build result must
be copied into the tree), duplicates GC policy onto the tree, and leaves
orphan narinfos on push failures. The edge cache addresses these availability
risks without any of that; the two approaches are not mutually exclusive if
a static tree is ever needed.

## Daemon lifecycle

`nix-daemon-custom` runs with `KillMode = "mixed"`: stopping the unit sends
SIGTERM to the main daemon, then SIGKILLs any per-connection workers still in
the unit's cgroup when the main process exits or the stop timeout expires.
In-flight dump/CI connections are terminated on restart, and no daemon worker
from the unit remains after the stop completes.

## Scheduling priority

The in-container nix-serve unit runs with `Nice = -5` and best-effort IO
class at top priority, while the forgejo-runner units keep defaults — a
deliberately mild edge so interactive cache fetches are not starved by
batch CI builds when the store disk is saturated.

## Operational note: store on a single HDD

For an HDD-backed cache store, schedule `zfs`/`sanoid` scrubs outside the
fleet's usual update windows. Scrub scheduling is consumer host configuration,
outside this module's scope; the edge cache can absorb only requests for
content that is still cached.

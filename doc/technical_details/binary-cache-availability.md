# Binary cache availability

The runner module's binary cache (`cache.domain`, nix-serve inside the
container fronted by a host nginx vhost — see
[`architecture.md`](architecture.md)) has three observed availability
failure modes. This document states each failure fully, then describes the
machinery that absorbs it. Normative requirements live in
[`openspec/specs/runner-cache/spec.md`](../../openspec/specs/runner-cache/spec.md).

## Failure modes

**Restart windows.** Every deploy switch that changes the runner container
restarts it, taking nix-serve down for roughly a minute (plus warmup while
`nix-daemon-custom` re-establishes the store view). The same deploy typically
triggers fleet auto-updates, so clients hit the cache exactly during the
outage and receive a 502 flood from nginx (connection refused upstream).

**Worker saturation under IO pressure.** nix-serve (Perl/Starman, 5 prefork
workers, one request per worker) generates every NAR on the fly
(`dump-path` + compression). On a host whose store lives on a single HDD
(e.g. a one-disk ZFS pool), a scrub or other heavy IO stalls each dump long
enough that all workers stay busy: new connections overflow the listen
backlog (reset → 502) or exceed the default 60s nginx proxy timeout
(→ 504). No crash or restart appears in the journal — the service simply
cannot keep up.

**Leaked daemon workers.** With `KillMode = "process"`, stopping
`nix-daemon-custom.service` signalled only the main daemon process; its
per-connection workers survived (`Unit process ... remains running after
unit stopped`), accumulating orphaned daemons across restarts.

## The nginx edge cache (default on)

`cache.nginxCache.enable = true` (default) adds a `proxy_cache` zone
(`nixtache-bincache`, at `/var/cache/nginx/nixtache-bincache` — the host
root filesystem, deliberately not the store disk) on the cache vhost:

- `/nar/*`: NARs are immutable → 30d positive TTL. `proxy_cache_lock`
  coalesces concurrent fetches of the same NAR into one upstream
  `dump-path` — N machines updating simultaneously cost one dump, not N.
- narinfo (`/`): 6h positive TTL (bounded so retain-GC'd paths don't leave
  stale narinfos forever), 1m negative TTL so freshly pushed paths become
  visible promptly.
- `proxy_cache_use_stale error timeout updating http_500 http_502
  http_503 http_504`: previously cached content is served through backend
  restarts, saturation and 5xx — clients in a restart window get the NAR
  instead of a 502.
- `proxy_read_timeout 300s`: a slow dump under IO pressure completes and
  *fills* the cache instead of timing out.

Cold (never-cached) paths still fail while the backend is down — the edge
cache cannot invent content. `cache.nginxCache.enable = false` restores the
plain proxy-pass vhost.

**Rejected alternative:** a static file-based binary cache tree served by
nginx directly (the pattern the ab-image staging store uses). It replaces
the on-demand read path with an explicit push path (every build result must
be copied into the tree), duplicates GC policy onto the tree, and leaves
orphan narinfos on push failures. The edge cache solves the observed
failure modes without any of that; the two approaches are not mutually
exclusive if a static tree is ever needed.

## Daemon lifecycle

`nix-daemon-custom` runs with `KillMode = "mixed"`: SIGTERM to the main
daemon, SIGKILL to any surviving per-connection workers after
`TimeoutStopSec`. In-flight dump/CI connections die on restart; nix clients
retry, and restarts coincide with switches anyway. No worker outlives the
unit.

## Scheduling priority

The in-container nix-serve unit runs with `Nice = -5` and best-effort IO
class at top priority, while the forgejo-runner units keep defaults — a
deliberately mild edge so interactive cache fetches are not starved by
batch CI builds when the store disk is saturated.

## Operational note: store on a single HDD

If the cache store sits on a single HDD (e.g. a one-disk ZFS pool), a
scrub saturates the disk for hours; during that window every on-the-fly
dump is slow, nix-serve workers stall, and clients see 502/504 bursts. The
edge cache absorbs fetches of previously-served NARs, but cold paths still
degrade. Scrub scheduling (`zfs`/`sanoid` timers) is the consumer's own
host configuration and out of this module's scope — schedule scrubs outside
the fleet's usual update windows.

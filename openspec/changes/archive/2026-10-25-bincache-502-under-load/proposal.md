# Proposal

## Why

The runner container's binary cache (`bincache.<domain>`) falls over precisely
when it is needed: fleet machines auto-update right after a deploy, and the
same deploy restarts the runner container — clients then face 502 floods
(1634 errors in one day on the reference host, in 1–5 minute bursts per
restart, plus multi-minute post-start warmup). Independently of restarts,
short 502/504 bursts occur under IO pressure: the Perl `nix-serve` (5 Starman
workers, one request per worker) generates every NAR on the fly
(`dump-path` + compress) from a ZFS pool on a single HDD, so a scrub or a
couple of machines pulling the same closure saturates all workers — the
listen backlog overflows (connection reset → 502) or responses exceed the
default nginx proxy timeout (→ 504). Additionally, `KillMode = "process"` on
`nix-daemon-custom` leaks daemon worker processes across restarts (observed
chronically), and nothing shields clients from any of this: identical NARs
are re-generated per request with no caching or request coalescing.

## What Changes

- **Shield the cache from backend downtime and slowness**: add an nginx
  caching layer on the cache vhost (`proxy_cache` for `/nar/` and narinfo,
  `proxy_cache_lock` to coalesce concurrent requests for the same NAR,
  `proxy_cache_use_stale` on error/timeout/5xx) so clients keep being served
  through backend restarts, worker saturation and slow dumps.
- **Shrink the restart windows**: decide in design between making the cache
  survive container restarts (e.g. a static file-based cache tree served by
  nginx directly — the ab-image staging store already works this way) and
  reducing container restart frequency/downtime for cache-relevant units.
- **Fix the daemon worker leak**: stop leaking `nix-daemon` worker processes
  on `nix-daemon-custom` restarts (`KillMode` semantics) without abandoning
  in-flight CI builds unaccounted.
- **Protect the cache from co-hosted load**: give nix-serve IO/CPU priority
  over CI builds inside the container (scheduling/weights), and document the
  ZFS-scrub-on-single-HDD interaction as an operational consideration.
- Tests for new option surface (pure-eval, per contributor contract) and docs
  updates (`doc/user_guide/`, `doc/technical_details/`).

## Capabilities

### New Capabilities

- `runner-cache`: availability and performance of the runner container's
  binary cache under restarts and load — nginx caching/coalescing behaviour,
  restart-window handling, backend worker protection, and the daemon
  lifecycle guarantees that underpin it.

### Modified Capabilities

<!-- runner spec covers container resource budgets, not cache availability;
     no existing requirement changes. -->

## Impact

- `modules/runner/cache.nix` — nginx vhost caching configuration; possible
  new `cache.*` options.
- `modules/runner/store.nix` — `nix-daemon-custom` service lifecycle
  (`KillMode`), possibly nix-serve scheduling priorities.
- `modules/runner/ab.nix` — shared vhost; staging-store location must
  coexist with the new caching config.
- `tests/` — new pure-eval assertions for cache options/behaviour.
- `doc/user_guide/quickstart.md` and/or a cache section, plus
  `doc/technical_details/` for the nginx caching and daemon-lifecycle
  internals; `doc/GLOSSARY.md` if new domain terms are introduced.
- No breaking option changes expected; defaults must keep existing
  behaviour available.

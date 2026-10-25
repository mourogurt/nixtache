# Tasks

## 1. nginx edge cache on the cache vhost

- [x] 1.1 Add `services.nixtache.runner.cache.nginxCache` options (`enable` default true, `maxSize`, `directory`, narinfo TTLs if surfaced) in `modules/runner/cache.nix` with full `description`s; verify eval: `nix-instantiate --parse modules/runner/cache.nix` and the flake's options docs build (`nix build .#optionsMarkdown`)
- [x] 1.2 Implement the `proxy_cache_path` zone (host side, under `directory`) and the `locations."/"` cache policy in `modules/runner/cache.nix` per design D1 (NAR long TTL, narinfo moderate positive TTL + ~1m 404 TTL, `proxy_cache_lock`, `proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504`, raised `proxy_read_timeout`); verify the ab staging location in `modules/runner/ab.nix` is untouched (static `root`, no cache directives)
- [x] 1.3 Extend the pure-eval suite (pattern: `tests/runner.nix`) with assertions: cache on by default (zone + `proxy_cache`/`proxy_cache_lock`/`proxy_cache_use_stale` present on the vhost), `nginxCache.enable = false` yields the plain proxy-pass config, staging location unaffected; verify with `nix build .#checks.x86_64-linux.runner`
- [x] 1.4 Docs: new `doc/technical_details/binary-cache-availability.md` covering the full problem statement (restart-window 502 floods, worker saturation under scrub IO, on-the-fly dump cost), the edge-cache policy and the rejected static-tree alternative, linking `openspec/specs/runner-cache/spec.md`; verify one-fact-one-file (no duplication with existing cache docs) and update the README map line for the runner module if the cache description changes

## 2. Daemon worker leak fix

- [x] 2.1 Change `nix-daemon-custom` to `KillMode = "mixed"` in `modules/runner/store.nix` with a self-documenting comment (per-connection workers must not outlive the unit — observed as chronic `Unit process ... remains running` records); verify eval of the unit's `serviceConfig.KillMode` in a pure-eval assertion
- [x] 2.2 Cover with a test asserting `KillMode` for `nix-daemon-custom` in customStore mode (extend `tests/runner.nix`); verify `nix build .#checks.x86_64-linux.runner`
- [x] 2.3 Document the lifecycle semantics in `doc/technical_details/binary-cache-availability.md` (SIGTERM to main, SIGKILL to stragglers after `TimeoutStopSec`, in-flight connections die and clients retry)

## 3. Scheduling priority for nix-serve

- [x] 3.1 Give the in-container nix-serve unit favourable scheduling (`Nice = -5`, best-effort IO class top priority) in `modules/runner/cache.nix` (or `store.nix` where the service is amended), per design D4; verify via pure-eval assertion that the unit carries the settings and forgejo-runner units do not outrank it
- [x] 3.2 Cover in `tests/runner.nix`; verify `nix build .#checks.x86_64-linux.runner`
- [x] 3.3 Add a diagnostic note to `doc/technical_details/binary-cache-availability.md` (from 1.4) for consumers whose cache store sits on a single HDD (e.g. ZFS pool): state the full failure scenario (scrub saturates the disk → on-the-fly dump-path stalls all nix-serve workers → 502/504 bursts), how the edge cache absorbs it, and that scrub scheduling is the consumer's own host configuration (out of module scope), linking `openspec/specs/runner-cache/spec.md`; verify the note states the problem fully for a public reader (AGENTS.md rule 6)

## 4. Integration checks

- [x] 4.1 Run `nix flake check --show-trace --all-systems` (options docs strictness + all pure-eval suites) and confirm green
- [x] 4.2 Run `openspec validate bincache-502-under-load --strict` and confirm green

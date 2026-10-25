# Spec Delta

## MODIFIED Requirements

### Requirement: Edge caching with request coalescing on the cache virtual host

The nginx virtual host serving `services.nixtache.runner.cache.domain` SHALL
cache NAR responses (`/nar/*`) from the in-container nix-serve upstream and
SHALL coalesce concurrent requests for the same NAR into a single upstream
fetch (cache lock), so N fleet machines pulling the same closure cost one
upstream `dump-path`, not N. The cache SHALL be enabled by default and the
module SHALL expose an option to disable it, restoring the plain
proxy-pass behaviour.

#### Scenario: Concurrent identical NAR requests are coalesced

- **WHEN** two or more clients request the same uncached `/nar/<hash>.nar`
  concurrently
- **THEN** the module's nginx configuration applies a proxy cache with
  request coalescing on the cache virtual host so only one upstream request
  is in flight for that NAR

#### Scenario: Slow NAR fill remains single-flight

- **WHEN** the first upstream NAR generation remains in progress for 30
  seconds while multiple clients request that same uncached NAR
- **THEN** no additional upstream request for that NAR starts, and the clients
  are served from the completed cache fill rather than racing duplicate dumps

#### Scenario: Caching layer can be disabled

- **WHEN** the consumer disables the caching layer via the module option
- **THEN** the cache virtual host contains no `proxy_cache` directives and
  proxies every request to nix-serve

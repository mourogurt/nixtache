# runner-cache Specification

## Purpose

Keeps the runner container's binary cache available and responsive for fleet
machines while the container restarts (deploy switches) or its store disk is
under IO pressure, by caching and coalescing at the nginx edge and by not
leaking daemon processes across restarts.

## Requirements

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

#### Scenario: Caching layer can be disabled

- **WHEN** the consumer disables the caching layer via the module option
- **THEN** the cache virtual host contains no `proxy_cache` directives and
  proxies every request to nix-serve as before

### Requirement: Stale-serving across backend failure

The cache virtual host SHALL serve previously cached NAR content when the
nix-serve upstream is down or failing (connection refused/reset, timeout,
5xx), instead of propagating the error to clients.

#### Scenario: Container restart during a fleet update

- **WHEN** the runner container restarts (deploy switch) while clients are
  fetching NARs that were served at least once before
- **THEN** those clients receive the cached NAR content rather than a 502/504

#### Scenario: Uncached path during backend downtime

- **WHEN** a client requests a NAR that has never been cached while the
  upstream is down
- **THEN** the request fails as before (the edge cache cannot invent content)

### Requirement: Negative-answer freshness for narinfo

The caching layer SHALL NOT serve stale negative answers (404) for narinfo
paths for longer than a short, configurable-bounded window, so newly pushed
store paths become visible to clients promptly after a build completes.

#### Scenario: Newly built path becomes visible

- **WHEN** a narinfo request 404s, and the referenced path is then added to
  the cache store
- **THEN** a subsequent narinfo request for the same path after the short
  negative-cache window returns the narinfo rather than a stale 404

### Requirement: No leaked daemon worker processes on daemon stop

When the custom nix-daemon unit (`nix-daemon-custom.service`) stops, no
`nix-daemon` worker processes of that unit SHALL remain running afterwards.

#### Scenario: Stop with in-flight connections

- **WHEN** the unit is stopped while client connections (nix-serve or CI
  jobs) are being served
- **THEN** after the stop completes, `systemd` reports no remaining processes
  for the unit (no `Unit process ... remains running after unit stopped`
  journal records)

### Requirement: Cache backend scheduling priority over CI build load

Within the container, the nix-serve service SHALL run with CPU and IO
scheduling priority at least as favourable as the CI runner services, so
interactive cache fetches are not starved by batch builds.

#### Scenario: Priorities present in the evaluated unit

- **WHEN** the container configuration is evaluated with the cache enabled
- **THEN** the nix-serve unit carries explicit scheduling-priority settings
  and the forgejo-runner units do not outrank it

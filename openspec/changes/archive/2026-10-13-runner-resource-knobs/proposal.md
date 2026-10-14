# Proposal

## Why

The runner container's resource surface is limited to `memoryMax`,
`memoryHigh` and `timeoutStartSec`, with defaults (`60G`/`58G`) that assume a
dedicated ~64 GB host. Real consumers share the host with other services
(e.g. Matrix synapse), so the container needs a smaller default budget and
fairness knobs for CPU and IO — otherwise a big Nix build starves co-hosted
services, and co-hosted services starve the build.

This was made concrete by an incident: a multi-hour `ungoogled-chromium` CI
build died with `builder failed due to signal 9` and no OOM trace anywhere
(host dmesg, journal, cgroup counters, both systemd-oomd instances all
clean). Debugging it showed that consumers have no documented way to size the
container or to answer "who killed my build": the container cgroup lives
under `machine.slice` (not `system.slice`), kernel OOM messages don't match a
naive `grep oom`, oomd kills never touch dmesg, and a CI-side job
cancellation surfaces as signal 9 via Nix's SIGTERM handler. That knowledge
belongs in the repo, not in one person's head.

## What Changes

- New options on `services.nixtache.runner`, applied to the
  `container@<name>` unit alongside the existing memory knobs:
  - `memorySwapMax` (`nullOr str`, default `null` = systemd `infinity`):
    swap ceiling for the container. With host zram, swap is what lets
    chromium-class link peaks survive a tight RAM budget.
  - `cpuWeight` (`nullOr int 1..10000`, default `null` = systemd 100):
    CPU share under contention (co-hosted services stay responsive while the
    build uses idle cores).
  - `ioWeight` (`nullOr int 1..10000`, default `null` = systemd 100): IO
    share under contention (fixup phases of large packages are IO-heavy).
- **BREAKING**: default `memoryMax` changes `"60G"` -> `"16G"` and
  `memoryHigh` `"58G"` -> `"14G"`. The previous defaults silently assumed a
  dedicated ~64 GB host; the new defaults budget the container for a shared
  host. Consumers on dedicated/big hosts must now set `memoryMax`/
  `memoryHigh` explicitly.
- New `doc/technical_details/` page: resource sizing + a "who killed the
  build" debugging decision tree (correct `machine.slice` cgroup paths,
  `memory.events`/`memory.peak`, kernel-log grep that actually matches OOM
  kills, the host+container oomd trap, and "signal 9 with clean logs = check
  CI-side job cancellation, not memory").
- `doc/user_guide/` sizing note: RAM budget + host swap (zram) as the peak
  buffer, `nixSettings.cores` vs `memoryMax` guidance, upgrade note for the
  changed defaults (inline, per repo rule against migration docs).
- Pure-eval test coverage in `tests/runner.nix` for every new/changed option
  (repo contract: every option is asserted).

## Capabilities

### New Capabilities

- `runner`: the Forgejo Actions runner module — container resource control
  (memory budget incl. swap ceiling, CPU/IO fairness weights) and the
  consumer-facing sizing/debugging documentation for it. This change creates
  the capability with the resource-control requirements; the module's other
  behaviours gain requirements as later changes touch them.

### Modified Capabilities

(none)

## Impact

- `modules/runner/default.nix`: three new options, two changed defaults, new
  `serviceConfig` directives on `container@<name>`.
- `tests/runner.nix`: new pure-eval assertions.
- Docs: new `doc/technical_details/` page; `doc/user_guide/quickstart.md`
  resource-limits mention updated; README.md map line if it lists limits.
- Consumers: **breaking** for anyone relying on the implicit 60G budget on a
  dedicated host — after upgrading, their container gets 16G unless they pin
  `memoryMax`/`memoryHigh`. Consumers with no swap on the host lose the
  chromium-survival story at 16G and must lower `nixSettings.cores` or raise
  `memoryMax`.

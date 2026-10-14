# Tasks

## 1. Resource options in modules/runner/default.nix

- [x] 1.1 Change `memoryMax` default `"60G"` -> `"16G"` and `memoryHigh` default `"58G"` -> `"14G"` (option descriptions updated to state the shared-host rationale); verify: `nix eval` of a `nixosSystem` with the module enabled shows `systemd.services."container@runner".serviceConfig.MemoryMax == "16G"` and `MemoryHigh == "14G"`
- [x] 1.2 Add `memorySwapMax` option (`types.nullOr types.str`, default `null`, description covers the zram peak-buffer role); apply `MemorySwapMax` on the container unit only when non-`null`; verify: `nix build .#optionsMarkdown` succeeds (docs build runs `warningsAreErrors`, so the description must exist and render)
- [x] 1.3 Add `cpuWeight` and `ioWeight` options (`types.nullOr (types.ints.between 1 10000)`, default `null`, descriptions note the advisory/host-controller caveat for IO); apply `CPUWeight`/`IOWeight` only when non-`null`; verify: `nix build .#optionsMarkdown` succeeds
- [x] 1.4 Extend `tests/runner.nix` pure-eval assertions: default budget is 16G/14G; `MemorySwapMax`/`CPUWeight`/`IOWeight` are absent from `serviceConfig` by default; each knob passes through when set (`"8G"`, `200`, `50`); custom `memoryMax`/`memoryHigh` still pass through; verify: `nix build .#checks.x86_64-linux.runner` report is all-ok

## 2. Documentation

- [x] 2.1 Create a new `doc/technical_details/` page on container resources: `machine.slice` cgroup placement (`/sys/fs/cgroup/machine.slice/container@<name>.service/`), what each limit/weight does, and the "who killed the build" decision tree (`memory.events`/`memory.peak`, kernel-log search matching "out of memory", the host+container systemd-oomd layers that never touch dmesg, CI-side job cancellation surfacing as signal 9); verify: page exists, is linked from the technical_details index/README map where sibling pages are linked, and duplicates no fact owned by another doc
- [x] 2.2 Update `doc/user_guide/` with sizing guidance (RAM budget for a shared host, host swap/zram as the build-peak buffer, `nixSettings.cores` vs `memoryMax` trade-off) and an inline upgrade note for the changed defaults (no standalone migration doc per repo rule); verify: the guidance renders and points to the technical_details page for internals
- [x] 2.3 Update the resource-limits mention in `doc/user_guide/quickstart.md` (currently lists `memoryMax`, `memoryHigh`, `timeoutStartSec`) to include the new knobs; check README.md and AGENTS.md map lines and update only if they enumerate resource options; verify: `grep -rn "memoryHigh" README.md AGENTS.md doc/` shows no stale enumeration

## 3. Validation

- [x] 3.1 Run `nix flake check --show-trace` (x86_64-linux) and verify all checks pass, including the updated runner suite
- [x] 3.2 Run `openspec validate runner-resource-knobs --strict` and verify the change is valid

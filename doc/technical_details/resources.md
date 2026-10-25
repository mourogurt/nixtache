# Container resources

How the runner container's resource limits work and how to diagnose a killed
CI build. Source of truth: `modules/runner/default.nix`. Consumer-facing
sizing guidance lives in [`doc/user_guide/quickstart.md`](../user_guide/quickstart.md);
this page owns the internals and the debugging decision tree. Requirements:
[`openspec/specs/runner/spec.md`](../../openspec/specs/runner/spec.md).

## Where the limits live

NixOS containers run `systemd-nspawn --keep-unit` with
`Slice = "machine.slice"` (see nixpkgs `nixos-containers.nix`), so the whole
payload is charged to the unit's own cgroup:

```
/sys/fs/cgroup/machine.slice/container@<name>.service/   # NOT system.slice/
```

`services.nixtache.runner.*` options map to `serviceConfig` on the host-side
`container@<name>` unit:

| option | directive | default | effect |
|---|---|---|---|
| `memoryMax` | `MemoryMax` | `"16G"` | hard limit; crossing it triggers the kernel cgroup OOM killer |
| `memoryHigh` | `MemoryHigh` | `"14G"` | throttling threshold: reclaim pressure (cold pages pushed to swap) starts here, before the hard limit kills |
| `memorySwapMax` | `MemorySwapMax` | unset | swap ceiling; unset = no module-level ceiling, host swap (e.g. zram) fully absorbs build peaks |
| `cpuWeight` | `CPUWeight` | unset | CPU share (1–10000) under contention; unset = systemd default 100 |
| `ioWeight` | `IOWeight` | unset | IO share (1–10000) under contention; unset = systemd default 100. Advisory: requires the host IO controller |

Unset knobs emit **no directive** — host-wide systemd policy
(`DefaultCPUWeight`, admin drop-ins) is not shadowed by the module.

## Who killed the build: signal 9 evidence tree

`builder failed due to signal 9` means *something* SIGKILLed the builder. No
single check is decisive; correlate evidence around the failure time:

1. **Memory pressure and cgroup OOM.** Inspect
   `/sys/fs/cgroup/machine.slice/container@<name>.service/memory.events` and
   `memory.peak`. A delta in `max` records attempts to exceed the limit, not
   necessarily a kill; a delta in `oom_kill` records a killed process but can
   result from either a memcg or global OOM. The counters are cumulative and
   reset when the container restarts.
2. **Global kernel OOM.** Search
   `journalctl -k | grep -iE "oom|out of memory|killed process"` and correlate
   the killed process and cgroup with the failed build. `dmesg` is a wrapping
   ring buffer; the persistent journal covers a longer interval when enabled.
3. **systemd-oomd.** This userspace killer does not normally leave a kernel
   OOM message. Inspect both `ManagedOOMMemoryPressure` and `ManagedOOMSwap`
   on the unit, its slice and relevant ancestors; `kill` enables monitoring,
   while descendants with `auto` can be candidates beneath a monitored
   ancestor. Check `journalctl -u systemd-oomd` on the host and
   `journalctl -m --machine <name> -u systemd-oomd` inside the container.
4. **CI-side cancellation.** A Forgejo server restart or job timeout can make
   the runner terminate the job; Nix's SIGTERM handler then kills its builder
   with SIGKILL, so the client can still print "builder failed due to signal
   9". Check `journalctl -u forgejo`, the job duration against
   `timeout-minutes`, and
   `journalctl -m --machine <name> -u forgejo-runner-<inst>` for cancellation
   records around the failure.

Missing resource evidence makes cancellation a candidate, not a certainty:
counters may have reset, logs may have rotated, and different killers leave
different evidence.

# Container resources

How the runner container's resource limits work and how to diagnose a killed
CI build. Source of truth: `modules/runner/default.nix`. Consumer-facing
sizing guidance lives in [`doc/user_guide/quickstart.md`](../user_guide/quickstart.md);
this page owns the internals and the debugging decision tree.

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

## Who killed the build: signal 9 decision tree

`builder failed due to signal 9` means *something* SIGKILLed the builder. Work
the tree top to bottom — each step is cheap and decisive:

1. **Container cgroup OOM** (build hit `memoryMax`):
   `cat /sys/fs/cgroup/machine.slice/container@<name>.service/memory.events` —
   non-zero `oom_kill` or `max` is a yes. `memory.peak` shows how far it got.
   Counters reset when the container restarts.
2. **Global kernel OOM** (host exhausted): kernel messages NEVER contain the
   substring "oom" — search
   `journalctl -k | grep -iE "out of memory|killed process"`.
   `dmesg` is a wrapping ring buffer; the journal is authoritative.
3. **systemd-oomd** — userspace killer, leaves nothing in dmesg. NixOS runs it
   by default, but it acts only on slices with `ManagedOOMMemoryPressure=kill`
   (`systemctl show <slice> -p ManagedOOMMemoryPressure`; default: none). It
   exists **both on the host and inside the container** (the container is a
   full NixOS): check `journalctl -u systemd-oomd` on the host and
   `journalctl -m --machine <name> -u systemd-oomd` for the container.
4. **CI-side cancellation** — the least obvious and, with clean logs, the most
   likely. A Forgejo server restart (e.g. host auto-update switching
   generations at night) or a job timeout makes the runner SIGTERM the job;
   Nix's SIGTERM handler kills its builder with SIGKILL, so the *client*
   lives long enough to print "builder failed due to signal 9". Check
   `journalctl -u forgejo` for a restart at the failure time, the job's
   duration against `timeout-minutes` (reusable workflows set 4320–4600;
   a workflow without it inherits the platform default), and
   `journalctl -m --machine <name> -u forgejo-runner-<inst>` for cancellation
   lines.

Steps 1–3 all leave *some* trace (counters, kernel log, oomd journal). Step 4
leaves none on the host — a signal 9 with everything clean is a cancellation,
not a memory problem.

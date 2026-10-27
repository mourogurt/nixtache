# Design

## Context

Run #80 (SHA `1625203`, full-matrix dispatch) classified from job logs:

| Cluster | Suites | Evidence | Verdict |
| --- | --- | --- | --- |
| Host kills | `ab-data-pool-vm`, `ab-ota-interrupted-vm`, `ab-ota-migrate-boot-vm`, `ab-ota-migrate-boot-override-vm`, `ab-ota-noop-vm`, `ab-ota-rollback-vm`, `overlay-nix-ab-swap-vm`, `overlay-nix-ota-invalid-{reconcile,reconcile-degraded,tmpfs,wipe}-vm` | `ConnectionResetError` on QMP the moment the created appliance machine starts; QEMU processes died | NOT host overload: every suite passes `create_machine(start_command=...)` a QEMU command hardcoding `-accel kvm` with no fallback, and the CI build sandbox cannot open /dev/kvm (EPERM via the device cgroup) — QEMU exits before the QMP handshake. The framework's declared-node VMs silently fall back to TCG under the same conditions. Fix: `-accel kvm -accel tcg` (KVM first) in every created-machine start command, centralized per D7 |
| Host kill | `runner-store-swap-clone-vm` | `builder failed due to signal 9 (Killed)` mid-build | genuine overload casualty of the unbounded ~30-way dispatch; prevented by max-parallel |
| Journal-after-reboot | `ab-deploy-self-vm`, `auto-update-vm` | console shows `* Successfully installed update '2'`, then `journalctl -u systemd-sysupdate \| grep 'Successfully installed'` exits 1 — in the SAME boot (no reboot happened; the logind session teardown that looked like a shutdown is normal post-logout cleanup) | test bug: on current systemd the update unit's canonical name is `systemd-sysupdate-update.service` (`systemd-sysupdate.service` is an Alias); journald records under the canonical name and `journalctl -u` does not resolve aliases — the grep queries nothing |
| Reboot without install | `ab-ota-e2e-{erofs,none,percent}`, `ab-ota-verify-vm` | the ssh trigger returned after ~4 s, no install ever ran, the suite waited for artifacts that never landed | the old action's chained `--wait`-update + reboot trigger cannot express install-then-reboot (Type=simple update unit; reboot-assessment sees the relabel mid-transfer) AND swallowed update failures (`\|\| echo ::warning::`) — see D3 |
| First-boot attest | `ab-vm` | `RESULT_BOOT_COMPLETE=active` but `RESULT_BLESS=unknown`; `systemd-bless-boot status` exits non-zero | expectation/contract mismatch on fresh image under QEMU — investigate |
| EROFS boot | `ab-compression-vm` | K4 squashfs boots fully (fstype/store/boot-complete ok) in the same run; K4 erofs times out at the login prompt with zero captured serial output — reproduced identically in runs #80 and #99, i.e. deterministic, NOT an overload artifact | erofs appliance boot stall under investigation (serial-tail diagnostics added to the pexpect driver; kernel has both squashfs and erofs as modules and nixpkgs auto-adds each fileSystems fsType to the initrd) |
| Opaque | `ab-ota-anywhere-vm` | `nix copy` during nixos-anywhere install fails with `experimental Nix feature 'ca-derivations' is disabled` — same assertion in runs #80 and #99, deterministic | the appliance closure is content-addressed; both nix sides of the ssh-store copy (deployer client + kexec-installer serve) must enable `ca-derivations` — fixed in the suite's node configs |

Non-goals: the Forgejo UI showing epoch start times / absurd durations for
workflow_dispatch runs (server-side quirk); the reusable-workflow artifact
concerns owned by `deploy-runner-contract-fixes`.

## Decisions

### D1 — vmtests.yml output contract (spec: ci-workflows)

The suite step becomes three phases: (1) `mkdir -p "artifacts/${SUITE}"`;
(2) `nix build -L --no-link --print-out-paths … > "artifacts/${SUITE}/full.log" 2>&1`
full transcript to file, never to the step stream; (3) print a verdict view
from the file: the test-driver section (from the suite's `=== … ===` banner
to EOF) when the test ran, else `build never reached the test` plus the last
~40 lines (mirroring nix's own `Last N log lines`). Extraction is a small
`awk`/`sed` against the banner the suites already print — stable because
the banners are part of each suite's output contract. On any outcome the
existing `Upload suite logs` step (`if: always()`) now finds
`artifacts/<suite>/full.log`; add `if-no-files-found: error` so a silent
no-op can never regress unnoticed. Job display name: `name: ${{ matrix.suite }}`
on the matrix job (drops the `suites (…)` prefix). Parallelism:
`strategy.max-parallel: 3` — seven concurrent suites ran green in run #80;
thirty killed the host; three keeps a full dispatch inside a few hours.

Run #80 post-mortem added two workflow defects to this scope. First, the
smoke tagging via matrix `include:` spawned extra never-starting jobs
(`suites (true, ab-ota-e2e)`, `suites (true, overlay-nix-ota-invalid-vm)`,
task_id 0, waiting forever) that keep the whole run — and its job-level
`concurrency: vmtests` group — hostage; smoke membership therefore moves
into the run step itself (a `SMOKE_SUITES` env list + bash case), the plain
suite matrix has no `include:`, and the job-level concurrency group is
dropped (it demonstrably did not serialize siblings under load and only
created the hostage situation). Skipped smoke jobs still write a `full.log`
marker so the `if-no-files-found: error` upload stays meaningful. Second,
`nix build`'s own retry of failed matrix jobs left `ab-staging-vm` attempt 2
pending forever on the overloaded runner — cancelling the wedged run is an
operational prerequisite for any new dispatch (the kvm runner stays occupied
by the zombie job otherwise).

### D2 — Journal assertion (ab-deploy-self-vm, auto-update-vm)

The run #80 job log disproves the first "volatile journal across reboot"
theory: in `ab-deploy-self-vm` B1 the console shows the install and the
failing `journalctl` in the SAME boot — no reboot ever happened (the
logind session teardown that looked like a shutdown is the normal 10s
post-logout user-manager cleanup). The real cause is unit naming: on
current systemd the stock update unit's canonical name is
`systemd-sysupdate-update.service` (`systemd-sysupdate.service` is only an
Alias), journald records messages under the canonical name, and
`journalctl -u` does not resolve aliases — so a grep on the alias finds
nothing right after a successful install. Fix: a shared
`assertSysupdateInstalled` helper in `tests/ab-ota-vm-lib.nix` that queries
BOTH unit names (a suite that overrides the unit — the gating tests —
records under the alias name), asserted before any reboot leg runs. The
same alias bug breaks the auto-update module's ab poll (its
`journalctl -u systemd-sysupdate` install-evidence grep never matches, so
`rebootPolicy = "if-needed"` can never reboot): the module queries both
names and waits for the update run's completion (see D3).

### D3 — Reboot only after install (spec: ab-ota)

The chained stock trigger `systemctl start --wait systemd-sysupdate.service
&& systemctl start systemd-sysupdate-reboot.service` cannot express
"install, then reboot": the update unit is Type=simple (its start job —
with or without `--wait` — returns when the process forks or fails, not
when a large transfer completes), and `systemd-sysupdate reboot` reboots
whenever a newer version than the booted one is INSTALLED, which becomes
true the moment the update relabels the inactive partition — BEFORE the
content transfer finishes. In run #80 the e2e/verify suites additionally
showed the failure mode where the update run terminates quickly without
installing anything and the old action swallowed that (`|| echo
::warning::`), leaving the suite to time out on artifacts that never land
with no diagnostics anywhere.

Fix, one mechanism in three places: a target-side
`nixtache-ab-update.service` (shipped by deploy-target for every `ab.enable`
target) starts the update, polls the unit until it is really
inactive/failed, and starts the reboot leg only on journal evidence
("Successfully installed", queried under both unit names per D2) from this
run — on failure or no-op it dumps the update journal and fails the unit.
The deploy action's remote leg SSH-starts that unit (a short exact string
the deploy user's SSH gate can whitelist; Type=oneshot, so the SSH call
returns the real outcome) and fails the target on non-zero instead of
warning. `nixtache-ab-apply` (runner-host gating) delegates to the same
unit and keeps the pending flag on failure. The auto-update module's ab
poll gets the same completion-wait + both-names evidence check (it must
NOT start the reboot leg — the reboot policy owns that).
`ab-ota-e2e.nix`/`ab-ota-verify-vm.nix` assert the new ordering (parse
guard + install-complete-before-reboot behavior) and the e2e suite gains
the negative scenario: staging unreachable → deploy fails, target not
rebooted, sysupdate journal surfaced in the target's deploy log.

### D4 — bless-boot on first boot (ab-vm) — resolved

Local reproduction on a KVM host boots the fresh image fully green:
`boot-complete.target` active AND `systemd-bless-boot status` = good —
Automatic Boot Assessment with boot counting attains a definite state on
first boot under the real path (OVMF → systemd-boot → UKI with +tries);
there is no module defect to wire. The run #80/#99 `RESULT_BLESS=unknown`
was the assertion tooling, not the image: `systemd-bless-boot` was not in
the appliance's PATH, the bare-name invocation produced nothing, and the
`|| echo unknown` fallback masked it — fixed by the fixture's
`abtest-systemd-aux-bins` (see D7). The strict assertion stays; the full
CI dispatch (task 9.2) is the confirmation on the runner.

### D5 — EROFS boot (ab-compression-vm) — resolved

Local reproduction on a KVM host: the K4 erofs appliance DOES reach its
kernel — the zero-serial picture in CI was the serial-tail slice landing
in the quiet window after the failure. The actual failure is erofs zstd
decompression on the store partition (`failed to decompress … Unknown
frame descriptor`, read error -117) → the initrd's NixOS Activation
fails → emergency shell, no login banner. Bisected across full appliance
images booted via the suite's exact SATA path: every image whose mkfs
carried `-C1048576` (big pcluster) fails; `-Efragments,ztailpacking`
without `-C` boots green; plain zstd boots green; mounting the broken
image's content over virtio in a warm system reads clean. Verdict: the
pinned kernel (6.18) cannot decompress erofs zstd pclusters at the 1M
size on the readahead path — 256K and 16384 pcluster images boot green
with the same flags. Fix (image definition): cap ab-image's erofs
big-pcluster option at `-C262144` — the compression win survives
(erofs+zstd-19 ≈ squashfs+zstd-19, K2 holds with margin) and boots are
green on the exact SATA path that killed them. Chasing the kernel fix
upstream (or a newer kernel pin) is out of scope for this change.

Additionally the size comparison itself was host-dependent: `du -B1`
sees repart's sparse zero-padding only when the store/filesystem
preserves holes (CI builder: yes; a btrfs store fed through NAR: no —
all variants measure 512M and K1/K2 false-fail). The suite now
re-punches the holes (`cp --sparse=always`) before measuring, making
K1–K3 deterministic on any host.

### D6 — ab-ota-anywhere (verdict from run #99)

Root cause (deterministic across runs #80/#99): the installed closure is
content-addressed, and nixos-anywhere's `nix copy --to ssh://target` has
two nix sides — the deployer's client nix and the kexec installer's
serving nix — both of which reject CA paths unless `ca-derivations` is
enabled. Fix: enable it in the suite's node configs (landed).

Placement (review): the suite's deployer deliberately does NOT
instantiate the runner container — its seam is the action's runtime env
contract (`GITHUB_*`/`NIXTACHE_*` env, credentials dir, PATH stubs); the
runner container machinery itself is covered by `runner-store-swap-vm`,
`runner-store-mode-vm` and `tests/runner.nix`. But everything the deploy
path consumes that is module-owned config must come from the module, not
be hand-copied: the runner container's forced `experimental-features`
list (`nix-command flakes ca-derivations`) moves into a single
importable definition under `modules/runner/`, consumed by the runner
container config, the suite's deployer node, and the suite's kexec
installer (its serving nix copies the same CA closure). A hand-written
feature list in a test is a drift defect: it stays green while a module
change breaks prod.

The suite's `nix-store --load-db < $(grep … regInfo … /proc/cmdline …)`
step is a runNixOSTest framework workaround: the driver puts a
double-prefixed `regInfo=` path on the guest kernel cmdline while the
guest mounts the host store directly at /nix/.ro-store, so the
framework's own register-nix-paths.service fails and the guest DB misses
the extraDependencies. A prod system boots a real disk — no `regInfo=`
cmdline and no register-nix-paths.service exist there — so the
workaround has no prod counterpart and cannot mask a prod defect; it
stays in the suite with a self-documenting comment.

### D7 — shared QEMU invocation, test-only fixture workarounds named

The KVM/TCG fallback contract — KVM first, TCG fallback for CI build
sandboxes where /dev/kvm is EPERM via the device cgroup — lives in
exactly one place: a parameterized start-command/base-args helper in
`tests/ab-ota-vm-lib.nix` (q35, `-cpu max`, `-accel kvm -accel tcg`,
OVMF, memory/smp, vde test-LAN netdev, snapshot drive). Suites that
create machines or spawn pexpect QEMUs consume the helper and contribute
only their deltas — extra disks with serials (`ab-data-pool-vm`),
`-no-reboot` (`ab-ota-anywhere-vm`), the pexpect serial-stdio shape
(`ab-vm`, `ab-compression-vm`, `overlay-nix-vm`) — instead of each
hand-rolling the full command. `tests/vde-repro.nix` and its
`probe-vde.yml` dispatch are temporary diagnostics of this change's
QEMU-death cluster; they are retired once CI verifies the fallback green.

`ab-fixture.nix`'s `abtest-systemd-aux-bins` symlinks the appliance's OWN
`systemd-bless-boot`/`systemd-sysupdate` (from `config.systemd.package`)
into PATH purely so assertions can invoke them by bare name from the
autologin shell. The appliance's units ExecStart them by absolute store
path, so prod functionality never depends on PATH — the symlinks are
assertion ergonomics, not a module gap, and a prod appliance needs
nothing of the sort.

## Risks / Trade-offs

- Verdict extraction depends on suite banners; mitigated by the banners
  being the suites' stable output contract and by the full log always being
  the artifact of record.
- `max-parallel: 3` lengthens a full dispatch (~serial sum of suites; the
  per-job 240 min timeout is unaffected). Acceptable for a manual/weekly
  matrix; the nightly smoke subset is unaffected.
- D3 changes trigger behavior; consumers that relied on "reboot regardless"
  would see the target stay up on failed updates — that is the intended,
  now-specified contract.

## Migration Plan

None required: workflow and test-surface changes only; the trigger change
(D3) alters behavior solely on the failure path (no-op/success paths
unchanged).

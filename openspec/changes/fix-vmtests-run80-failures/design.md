# Design

## Context

Run #80 (SHA `1625203`, full-matrix dispatch) classified from job logs:

| Cluster | Suites | Evidence | Verdict |
| --- | --- | --- | --- |
| Host kills | `ab-data-pool-vm`, `ab-ota-interrupted-vm`, `ab-ota-migrate-boot-vm`, `ab-ota-migrate-boot-override-vm`, `ab-ota-noop-vm`, `ab-ota-rollback-vm`, `overlay-nix-ab-swap-vm`, `overlay-nix-ota-invalid-{reconcile,reconcile-degraded,tmpfs,wipe}-vm` | `ConnectionResetError` on QMP the moment the second VM starts; QEMU processes died | infra: ~30 KVM suites at once on one runner; no code fix, prevent with bounded parallelism |
| Host kill | `runner-store-swap-clone-vm` | `builder failed due to signal 9 (Killed)` mid-build | infra, same prevention |
| Journal-after-reboot | `ab-deploy-self-vm`, `auto-update-vm` | console shows `* Successfully installed update '2'`, then `journalctl -u systemd-sysupdate \| grep 'Successfully installed'` exits 1 | test bug: the flow rebooted the target; the volatile journal of the installing boot is gone |
| Reboot without install | `ab-ota-e2e-{erofs,none,percent}`, `ab-ota-verify-vm` | target shuts down (user sessions teardown) while `abtest_2+*.efi` never appears; waits time out at 180/300 s | sysupdate installed nothing; the reboot leg fired anyway |
| First-boot attest | `ab-vm` | `RESULT_BOOT_COMPLETE=active` but `RESULT_BLESS=unknown`; `systemd-bless-boot status` exits non-zero | expectation/contract mismatch on fresh image under QEMU — investigate |
| EROFS boot | `ab-compression-vm` | K4 squashfs boots in ~66 s; K4 erofs emits zero serial bytes for 240 s | unbootable erofs image or boot-chain break — investigate |
| Opaque | `ab-ota-anywhere-vm` | `AssertionError: nixos-anywhere failed with 1`, nothing captured before it | needs logs to diagnose |

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

### D4 — bless-boot on first boot (ab-vm)

Investigate by reproducing locally (`nix build .#vmTests.x86_64-linux.ab-vm`
on a KVM host): query `systemd-bless-boot status`, `bootctl`, and the ESP's
loader entries on the fresh image. Two outcomes: (a) the image does not
configure boot counting / systemd-boot variables under QEMU → the module
(`modules/ab-image/` or `modules/deploy-target/`) wires it, and the
assertion stays strict; (b) ABA on this platform legitimately attests via
`boot-complete.target` without a queryable bless state → the test asserts
the attainable contract (boot-complete + slot integrity) and documents why
bless status is `unknown` on first boot. Choose (a) only with a concrete
module defect in hand; otherwise (b). If (a) wins, extend the ab-ota delta
in this change with the wiring requirement before implementing.

### D5 — EROFS boot (ab-compression-vm)

Zero serial bytes means the kernel never started — not an initrd mount
failure (that would still print early boot). Reproduce locally; inspect the
erofs repart image (ESP contents, kernel presence, partition offsets)
against the squashfs one. Fix wherever the difference originates (image
definition in `modules/ab-image/`, or the test's image assembly), keep K1–K3
and both K4 boots; the squashfs K4 regression-guards the shared path.

### D6 — ab-ota-anywhere

Re-run after D1 lands so the full transcript is an artifact; root-cause
from it (suspects: ssh/disk-full/kexec under the appliance fixture). No
design commitment until the log exists — the task is investigation-first
with the fix to follow in this change.

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

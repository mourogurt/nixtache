# Tasks

- [x] 1. vmtests.yml diagnosability rework (design D1)
  - [x] 1.1 Capture the suite step's full `nix build -L` transcript to
        `artifacts/<suite>/full.log` instead of the step stream
  - [x] 1.2 Print only the verdict view: test-driver output when the test
        ran, else "build never reached the test" + last ~40 log lines
  - [x] 1.3 Make `Upload suite logs` upload that file on every outcome and
        fail on missing files (`if-no-files-found: error`)
  - [x] 1.4 Name matrix jobs after their suites (`name: ${{ matrix.suite }}`)
  - [x] 1.5 Bound full-matrix concurrency (`strategy.max-parallel: 3`) with
        a comment stating the run #80 kill threshold rationale
- [x] 2. Journal-across-reboot assertions (design D2)
  - [x] 2.1 Add a shared `assertSysupdateInstalled` helper in
        `tests/ab-ota-vm-lib.nix` that asserts in the installing boot
        (pre-reboot query or console evidence)
  - [x] 2.2 Use it from `tests/ab-deploy-self-vm.nix` and
        `tests/auto-update-vm.nix`; remove the post-reboot `journalctl`
        greps
- [x] 3. Reboot-only-after-install guard (design D3, ab-ota delta)
  - [x] 3.1 Gate the trigger's reboot leg on the update run reporting a
        successful installation; on failure propagate the sysupdate error
        and leave the target running
  - [x] 3.2 Update `tests/ab-ota-e2e.nix` and `tests/ab-ota-verify-vm.nix`
        to assert install-then-reboot ordering with the real error surfaced
  - [x] 3.3 Add the negative scenario (staging unreachable → no reboot,
        sysupdate error surfaced) to the e2e suite
- [x] 4. ab-vm bless-boot resolution (design D4)
  - [x] 4.1 Reproduce locally; capture `systemd-bless-boot status`,
        `bootctl`, and ESP loader-entry state on the fresh image
  - [x] 4.2 Implement outcome (a) module wiring or (b) assertion aligned
        with the attainable first-boot contract, with the rationale
        recorded in the test
- [x] 5. EROFS boot root cause (design D5)
  - [x] 5.1 Reproduce `ab-compression-vm` K4 locally; diff the erofs image
        (ESP, kernel, offsets) against the squashfs one
  - [x] 5.2 Fix the origin (image definition or test assembly); keep K1–K3
        and both K4 boots intact
- [x] 6. ab-ota-anywhere root cause (design D6)
  - [x] 6.1 Diagnose the `nixos-anywhere failed with 1` exit (run #99
        pinned the same deterministic assertion; verdict in design D6)
  - [x] 6.2 Fix the identified cause (ca-derivations on both nix sides of
        the CA closure copy)
- [x] 7. Documentation (per repo rule)
  - [x] 7.1 Update `doc/technical_details/testing.md`: vmtests job output
        contract, full-log artifact layout, job naming, and bounded matrix
        concurrency, linking `openspec/specs/ci-workflows` and
        `openspec/specs/ab-ota`
  - [x] 7.2 Update `README.md` repository map if the artifact/log layout
        changes what CI produces
- [x] 8. Test-surface hygiene from review (design D6/D7)
  - [x] 8.1 Extract the runner container's forced `experimental-features`
        into a single importable definition under `modules/runner/`
        (exported via the flake); consume it in the runner container
        config, the anywhere suite's deployer node, and its kexec
        installer config; delete the hand-copied lists from the suite
  - [x] 8.2 Consolidate created-machine/pexpect QEMU invocations onto one
        parameterized helper in `tests/ab-ota-vm-lib.nix`; suites keep
        only their deltas: `ab-data-pool-vm`, `ab-ota-anywhere-vm`,
        `overlay-nix-ab-swap-vm`, `overlay-nix-ota-invalid-vm`, `ab-vm`,
        `ab-compression-vm`, `overlay-nix-vm`
  - [x] 8.3 Make the suite/fixture comments state the no-prod-surface
        facts explicitly: the regInfo `nix-store --load-db` step is a
        runNixOSTest framework quirk (no `regInfo=` cmdline exists on a
        prod system); `abtest-systemd-aux-bins` is assertion ergonomics
        (units ExecStart absolute store paths — no prod impact)
  - [x] 8.4 Retire the temporary `tests/vde-repro.nix` diagnostic and its
        `probe-vde.yml` dispatch (flake.nix `vmTests` entry included)
- [ ] 9. Verification
  - [x] 9.1 Local: `nix flake check --show-trace --all-systems` and the
        affected pure-eval suites stay green
  - [ ] 9.2 CI: dispatch a full `vmtests` run on a healthy KVM runner;
        confirm bounded parallelism, verdict-only job output, uploaded
        per-suite logs, and green suites for every cluster fixed here
  - [x] 9.3 Root-cause the run #105 failures (first full-matrix dispatch
        that completed): `ab-data-pool-vm` predates the wipe-on-cutover
        default change and must pin its intended policy explicitly
        (`upperOnUpdate = "reconcile"` — the reference-server contract the
        suite's assertions describe); `runner-store-swap-clone-vm` broke
        deterministically at the nixpkgs bump (276dd60): the pinned
        nixos-containers.nix binds the host's /nix/var/nix/db only when the
        host has nix enabled, so the appliance-mode container lost the
        lower-DB — the module binds it read-only itself, pinned in
        tests/runner.nix
  - [x] 9.4 Root-cause the remaining run #116/#117 failure
        (`ab-deploy-self-vm`): systemd 262 renamed the update oneshot to
        `systemd-sysupdate-update.service` (old name = compat alias;
        alias-named drop-ins are ignored), so the suite's fail-on-demand
        wrapper never ran and the gnupg PATH drop-ins in ab-image /
        ab-provision went inert — wrapper retargeted to the canonical name,
        gnupg path set on the canonical name in both modules

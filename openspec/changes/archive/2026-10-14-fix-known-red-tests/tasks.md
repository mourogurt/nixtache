# Tasks

## 1. W1 — restore the ab-deploy-drift report contract (CI green)

- [x] 1.1 Rewrite `tests/ab-deploy-drift.nix`'s builder so the report lands
  in `$out` as a regular file (pattern: accumulate ok/FAIL lines in a
  scratch file, then `cp` it to `$out`, as `tests/auto-update.nix` does);
  drop the `mkdir -p $out` / `$out/report` directory shape. Keep the
  builder's printed output and the failure exit (`FAIL=1`) semantics
  unchanged. Verify: `nix build -L .#checks.x86_64-linux.ab-deploy-drift`
  succeeds AND `test -f ./result` (not a directory) AND `cat ./result`
  shows the three `ok` lines.
- [x] 1.2 Confirm the CI loop contract end-to-end locally: run the exact
  command `ci.yml` uses per-suite —
  `out=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.ab-deploy-drift) && cat "$out"`
  — and verify it exits 0 with the report on stdout.

## 2. W2 — reproduce and diagnose on the current tree (KVM required)

- [x] 2.1 Run `nix build -L .#vmTests.x86_64-linux.ab-ota-verify-vm` on a
  KVM host. Capture: full suite log, and on failure the target's
  `journalctl -u 'systemd-sysupdate*' --no-pager` (add a temporary
  diagnostic `target.succeed(...)` if the suite aborts before its own
  journal dumps — include `(sd-pull)` / `(gpg)` child lines). Deliverable:
  the observed C4 failure mode written into the change notes with the
  decisive journal lines (green no-op vs verifier error vs other).
- [x] 2.2 If (and only if) C4's diagnosis is inconclusive from the unit
  journal, reproduce the trigger by hand inside the suite's world is NOT
  required — instead extend the temporary diagnostics (e.g.
  `SYSTEMD_LOG_LEVEL=debug` drop-in on the unit, `ls -l /etc/systemd/`
  for the keyring, `command -v gpg` in the unit's context) and re-run.
  Verify: the failing link in
  manifest-download → gpg-verify → candidate-selection is named with
  evidence.
- [x] 2.3 Apply the minimal fix at the layer the diagnosis indicts
  (test-local > module wiring > action text, per design D3), re-run task
  2.1's command until C4 passes for the right reason (v2 written,
  `abtest_2+*.efi` present, negatives C1–C3 still rejected — the suite's
  own assertions are the verification).
- [x] 2.4 While touching the file: delete the duplicated
  `system.image.id` / `system.image.version` block in
  `tests/ab-ota-verify-vm.nix` (verbatim copy-paste; last-wins today).
  Verify: `nix flake check --show-trace --all-systems` still evaluates
  (the suite is not a checked output, but its file must parse).

## 3. W2 — anywhere suite green

- [x] 3.1 Run `nix build -L .#vmTests.x86_64-linux.ab-ota-anywhere-vm` on a
  KVM host (only after 2.3 — the OTA leg shares verify-vm's machinery).
  If it fails, capture the installed machine's sysupdate journal (the
  suite already dumps a tail; extend if needed) and fix at the indicted
  layer. Verify: the suite's own PASS line
  (nixos-anywhere install → signed OTA → slot B = v2, slot A intact).
- [x] 3.2 Confirm no regression in the neighbouring KVM suites that share
  the touched code: at minimum `ab-ota-e2e`, `ab-deploy`, `ab-ota-rollback-vm`,
  `ab-ota-interrupted-vm` via `vmtests.yml` dispatch (smoke set) or
  individual `nix build -L .#vmTests.x86_64-linux.<suite>` runs. All green.

## 4. CI + docs

- [ ] 4.1 Push-driven verification: `ci.yml` run on this branch's merge to
  `main` is green end-to-end — in particular the "Run module tests" step
  prints the drift suite's report (not `Is a directory`) and every
  checks-suite report ends without a failing exit.
- [x] 4.2 Remove the "Known red" paragraph from
  `doc/technical_details/testing.md` (lines ~65–73) once 2.3 and 3.1 are
  green; keep the VM-suite inventory accurate. Verify: no other doc still
  claims those suites are red (`rg -n "Known red|ab-ota-anywhere-vm"
  README.md doc/ openspec/` returns only historical/archive hits).
- [x] 4.3 Reconcile the diagnosis findings into the owning doc exactly
  once (facts live in one file only): if a new operational invariant was
  discovered (e.g. "every unit that can trigger a pull needs the verifier
  on PATH"), it belongs in `doc/technical_details/module-ci-wiring.md` or
  the OTA internals doc — not duplicated across files. Verify: the fact
  appears in exactly one `doc/` file and the others link to it.

# Design

## Context

Two independent failures share this change; they are kept together only
because both are "make the documented test contract true again".

**W1 — CI red (deterministic, fully understood).**
`doc/technical_details/testing.md` fixes the suite contract: a test file is a
`runCommand` whose builder "prints a human-readable report … into `$out`",
and both `ci.yml`'s report loop (`cat "$out"`, ci.yml:55) and the documented
manual invocation (`nix build .#checks.<system>.<suite> && cat ./result`)
assume `$out` is a regular file. Every suite honours this except
`tests/ab-deploy-drift.nix`, which does `mkdir -p $out` and writes
`$out/report` — so CI runs 30/31 fail at the last suite with
`cat: …: Is a directory` even though all its checks pass.

**W2 — known-red VM suites (failure mode NOT current).**
testing.md's "Known red" paragraph records, as observed on clean `fa1284a`:

- the remote trigger (`systemctl start systemd-sysupdate-reboot.service`) on
  `ab-ota-anywhere-vm` and the C4 leg of `ab-ota-verify-vm` settles into a
  green no-op after the booted-version assessment instead of discovering the
  staged update (suite times out waiting for `abtest_2+*.efi` / `nix-store_2`);
- a manual plain update logs `Signature verification failed` against the
  action-signed manifest.

That recording **predates** commit 663158f (ota-stabilization), which already
shipped targeted fixes in exactly this area — `path = [ pkgs.gnupgMinimal ]`
on both `systemd-sysupdate.service` and `systemd-sysupdate-reboot.service`
in `modules/ab-image/default.nix` and `modules/deploy-target/ab-provision.nix`
— and claims all *new* suites green on KVM. The two known-reds were not
re-run after those fixes; their current failure mode is an open question that
must be answered from journals before fixing.

Pinned environment: nixpkgs `dfce2e0` (nixos-26.11 pre, 2026-08-04) with
**systemd 261.1** and **gnupg 2.4.9**.

### How systemd 261 verification actually works (code-read evidence)

Read from upstream `main` (~v261) sources; this is the machinery any fix
plays against:

1. For a URL `Source=`, version discovery downloads the manifest:
   `sysupdate-resource.c: download_manifest()` forks
   `systemd-pull raw --direct --verify signature <src>/SHA256SUMS -`
   (`--verify signature` iff `Transfer.Verify=yes`).
2. `pull-common.c: pull_verify()` → `verify_gpg()` **execs `gpg2`/`gpg` via
   `execvp` from the calling process's PATH** with a throwaway homedir and
   `--trust-model=always`, keyrings taken from
   `$SYSTEMD_OPENPGP_KEYRING` (if set) or the fixed user/vendor keyring
   paths. Since v258 the canonical keyring name is
   `import-pubring.pgp` (renamed from `.gpg`; the legacy name is still
   consulted). If the manifest verification fails, `download_manifest`
   returns `-EPROTO` — source discovery dies.
3. `sysupdate.c: context_acquire()`: with no candidate update set it logs
   `No update needed.` and exits **0** — a green no-op. Candidates are
   suppressed when `newest_installed >= candidate`
   (`context_discover_update_sets`). This is how a verification failure on
   the manifest turns into the observed "green no-op after the booted-version
   assessment" instead of an error: no source versions ⇒ no candidate ⇒
   success-with-nothing.
4. The booted-version assessment itself (`pending`/`reboot` subcommands and
   the post-install reboot decision) compares `IMAGE_VERSION` from os-release
   against installed instances — both suites already satisfy its
   preconditions (`system.image.version = "1"` on the verify-vm target; the
   appliance's image-version file on anywhere-vm).

Implication: the recorded symptoms are all consistent with **one** fault —
manifest signature verification failing inside the pull fork — which then
surfaces as either "Signature verification failed" (plain unit, journal kept)
or a green no-op (`--reboot` unit, discovery dies quietly upstream of any
version logic). The already-landed gnupg-on-PATH fixes address the most
likely historic cause (empty PATH ⇒ execvp fails ⇒ verifier pipe breaks);
whether that fully closes it on systemd 261.1 is precisely what reproduction
must show.

## Goals / Non-Goals

**Goals**

- W1: `ci.yml` green on `main` with zero behavioural change to what the
  drift suite verifies.
- W2: `nix build -L .#vmTests.x86_64-linux.ab-ota-verify-vm` and
  `.#vmTests.x86_64-linux.ab-ota-anywhere-vm` pass on a KVM host; the
  "Known red" paragraph leaves testing.md.
- Every fix step lands with the journal evidence that justified it.

**Non-Goals**

- No new suites, no coverage-gate work (tracked separately per testing.md).
- No nixpkgs pin change; fixes must live on the current pin.
- No relaxations (e.g. flipping `Verify=no`, loosening MatchPatterns, or
  weakening assertions) — the suites must pass for the right reason. A fix
  that weakens the contract is a spec change and out of scope here.
- No boot-into-slot-B cycle for anywhere-vm (documented simplification,
  owned by `ab-vm.nix`).

## Decisions

**D1 — W1 fix shape: write the report to `$out` as a file, not a directory.**
Match the contract every other suite implements (cf. `tests/auto-update.nix`:
build the report in a scratch file, `cp` to `$out`). Keep the builder's
stdout identical (the ok/FAIL lines it prints are also read via
`--print-build-logs`). Alternative — teach `ci.yml` to `cat "$out"/report`
per-suite — rejected: it forks the contract between suites and desyncs the
documented manual command from CI.

**D2 — W2 is reproduce-first; the recorded failure mode is a hypothesis, not
a premise.** First task on a KVM host runs the C4 leg (verify-vm is the
cheaper of the two: two plain nodes, no nixos-anywhere) and captures
`journalctl -u systemd-sysupdate*` (and the `(sd-pull)`/`(gpg)` child
output) before any edit. Anywhere-vm runs only after verify-vm's C4 is
green — its install phase is long and its OTA leg shares the same machinery,
so it would only re-buy the same journal at 10× the cost.

**D3 — fixes are allowed exactly where the diagnosis points, in this order of
preference** (test-local → module wiring → action text), because blast
radius increases in that order:

1. *Test-local* (fake environments, unit preconditions, key material):
   e.g. the fixture key, pubring install paths in the suites' host configs.
2. *Module wiring* (`ab-image`, `ab-provision`): verifier PATH for every
   unit that can run a pull (both units are currently covered — a diagnosis
   may reveal a third path, e.g. the D-Bus `systemd-sysupdated` route or a
   timer-driven unit), keyring file naming, transfer/MatchPattern shape.
3. *Action text* (`.forgejo/actions/deploy-target/action.yml`): signing
   invocation or manifest shape — last resort; any change there must keep
   the drift suite's greps (`protocol drift`, `return 2`) and the e2e/verify
   suites' action-text assertions true, since they pin the same file.

**D4 — green means both trigger paths, asserted by the suites as written.**
C4 exercises the action's SSH trigger (`systemd-sysupdate-reboot.service`);
the negatives' `attempt_v3` exercises the plain unit. Both must behave as
the suite already specifies; no assertion edits unless the diagnosis shows an
assertion wrong on its own merits (e.g. a journal grep that can't match
systemd 261 wording), in which case the edit lands with a comment stating
the invariant it checks.

**D5 — duplicate `system.image.*` block in verify-vm is deleted outright.**
It is a verbatim copy-paste (same values, same comment twice); Nix accepts
it (last-wins) but it invites drift. No behavioural effect.

**D6 — suites exercise the stock units; no ExecStart overrides on the flow
under test** (user review flagged the pre-existing e2e reboot-unit override
as corner-cutting — you cannot override units on a production system, so the
suites must not either). Root cause confirmed on KVM (2026-10-14): on the
pinned systemd 261.1 the stock `systemd-sysupdate-reboot.service` runs
`systemd-sysupdate reboot` — a purely OFFLINE assessment that reboots only
when a NEWER version is already installed and never fetches; the fetch lives
in `systemd-sysupdate.service` (`update`, Type=simple, never reboots).
Neither unit alone is the old `update --reboot`. Fix at the two production
surfaces (action.yml remote trigger; ab.nix self-apply script): chain
`systemctl start --wait systemd-sysupdate.service && systemctl start
systemd-sysupdate-reboot.service` — `--wait` because Type=simple returns at
fork — and consume `ab-pending` after the update (the slot write the flag
guards), not after the reboot start. Consequences for the suites: e2e's
reboot-unit override is REMOVED and its target gains `system.image.version`
(so the reboot assessment is meaningful); verify-vm and anywhere-vm run the
real path and ride out the resulting reboot — driver 1.1 mechanics:
declared nodes run QEMU with `-no-reboot`, so a spontaneous reboot is QEMU
exiting (sanctioned recovery: `wait_for_shutdown()` + `start()`, same
disks), while the anywhere custom QEMU (no `-no-reboot`) resets in place
with surviving chardev sockets (`connected = False` + boot-id-change
wait); verify-vm's negatives use `--wait` on the plain unit (Type=simple
otherwise returns before the rejection lands in the journal). One more
indicted surface surfaced during implementation: the deploy user's SSH
forced-command gate whitelists exact command strings — the new chained
trigger had to replace the two stale single-unit entries
(`modules/deploy-target/user.nix`). `ab-deploy-self-vm` keeps
test-doubles ONLY as dependency seams — its subject is gating, not
sysupdate — with the fail-on-flag wrapper moved to the plain update unit
(the failure point that guards pending consumption) and the reboot unit as
a no-op.

## Risks / Trade-offs

- **Stale evidence**: if reproduction shows the suites already green after
  663158f, W2 collapses to "re-verify + delete the Known-red paragraph" —
  acceptable; the change then ships W1 plus docs.
- **Upstream-moving target**: systemd's verifier internals changed across
  258→261 (keyring rename, exec-gpg rework). Fixes pin to observed 261.1
  behaviour with code-level citations in the diagnosis notes/commit message,
  not to folklore.
- **KVM availability**: both W2 suites need the `kvm`-labelled runner (or a
  local KVM host); the design deliberately front-loads the cheap suite.

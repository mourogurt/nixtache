# Design

## D1 — Root cause: CA alias flattening breaks cross-context hash identity

The appliance fixtures build with `appliancePkgs` =
`import nixpkgs { config.contentAddressedByDefault = true; }`. When paths
from that CA context cross into another derivation context (the test
derivation itself, the registration dump, a `nix copy`), Nix rewrites
their store names to flattened aliases:

```
original:  /nix/store/awji8v7djlp0whjbcs2fyybwr02fgzd1-disko
aliased:   /nix/store/r8xf1kdin0z3cbzx19az5ml9rxsdq1kj-awji8v7djlp0whjbcs2fyybwr02fgzd1-disko
```

Observed facts (local reproductions of the CI failure, run #103 job
`ab-ota-anywhere-vm`):

- The deployer's registration dump (closure-info, 11504 lines) records
  CA closure members under alias names. An in-VM `nix-store --load-db`
  of that dump therefore never marks the *original-named* paths valid
  that an in-VM evaluation computes. Stripping the alias prefix with sed
  loads the original names, but the corresponding *directories* in the
  shared store exist (where at all) under still other names — validity
  and presence never converge.
- nixpkgs and disko sources reach the sandbox only in mixed forms
  (nixpkgs source present solely under its alias,
  `a7yw70p8dny91l9a2ccbik1vzbdhq1ff-gjq7…-source`), so even reading the
  intended inputs inside the VM is unreliable.
- The host realized the rewritten derivation
  (`y7wc9pf…-disko.drv` → output `awji8v…-disko`), while in-VM
  evaluation computes the canonical derivation
  (`6r71x8…-disko.drv`). The canonical derivation was built by nobody:
  the planned "no-op" build turns into a full closure rebuild (peak
  observed plan: 1246 derivations), whose fixed-output tarball fetches
  fail — the VMs are network-less by design (hermeticity).
- `--pure-eval` refuses to fetch `path:` flake inputs, and a flake copied
  into the read-only store cannot write the lock file that would pin
  them; an experiment vendoring the nixpkgs and disko trees *into* the
  flake directory (input-less flake + a `nixpkgs` shim re-exporting
  `nixosSystem` from the vendored tree) made host and VM evaluations
  bit-identical — and the build still failed on the never-built
  canonical derivation. This isolates the failure to store-side identity,
  not evaluation determinism: under CA + hermetic VM, "in-VM build no-ops
  against host pre-builds" is unachievable in general.

Constraint kept by everything above: `modules/ab-image` asserts
`pkgs.config.contentAddressedByDefault` — CA is load-bearing for the
sysupdate payloads (raw slot images embed store validity records tied to
content addresses), so "just build the install config without CA" would
trade one broken invariant for another unless scoped precisely (see O2).

## D2 — Options

- **O1 — keep the in-VM evaluation, keep patching name mismatches.**
  Rejected: D1 shows the mismatch is structural (which derivation the
  realization must run), not cosmetic (which names the DB holds). Every
  patch (load-db alias stripping, vendored inputs) moved the failure one
  layer deeper without changing the outcome.
- **O2 — build the install-time system in a non-CA context, keep the
  sysupdate payloads CA.** The installed v1 system is an ext4 closure,
  not a raw slot image; CA is not intrinsically required for it. This
  needs a scoped relaxation of the ab-image CA assertion (assert on the
  image/payload outputs, not on `config.system.build.toplevel` use) and
  a product-level statement that mixed-CA lifecycles (IA install, CA
  updates) are supported. Viable, but touches a load-bearing product
  invariant for a test-harness benefit. Fallback if O3 proves
  impossible.
- **O3 — no in-VM evaluation: transport the closure, drive the wire.**
  The test evaluates once, in the single CA context on the host, and
  interpolates the pre-built paths. The deployer VM runs the steps
  nixos-anywhere performs for a remote target: kexec into the installer,
  disko the A/B layout, transfer the closure, `nixos-install`, reboot.
  Names stay consistent end-to-end (one context); nothing in a VM ever
  evaluates a flake; hermeticity is preserved. The dropped surface is
  the `nixos-anywhere --flake` CLI entrypoint exercised inside a VM —
  which no real runbook does (operators evaluate on their own host).
  **Chosen.**
- **O4 — give the deployer VM network/cache access.** Rejected: breaks
  the suite's hermeticity contract and makes CI results depend on
  external infrastructure.

## D3 — Decision and consequences

Proceed with O3. Consequences:

- The suite's header contract (hermeticity paragraph) is rewritten from
  "every in-VM `nix build` is a store no-op via hash-match" to "no `nix`
  command inside a VM evaluates or builds; the deployer drives wire steps
  over pre-built store paths interpolated by the test".
- During implementation, verify the nixos-anywhere CLI surface for
  pre-built closures (e.g. store-path arguments accepted by the current
  pinned version). If the CLI cannot consume them, drive kexec + disko +
  closure transfer + `nixos-install` directly, mirroring nixos-anywhere's
  own `tests/from-nixos.nix` approach, and record the dropped
  `--flake`-entrypoint coverage in the suite header.
- The CA-closure *copy* mechanics fixed by `fix-vmtests-run80-failures`
  task 6 (`ca-derivations` feature set via `modules/runner/nix-features.nix`)
  remain in use for the transfer step.
- O2 stays documented as the fallback, including the ab-image assertion
  scoping it would require, so a future blocker on O3 does not restart
  the investigation from zero.

## D4 — Parking mechanics

Until the rework lands, the suite is excluded from the `vmtests.yml`
matrix with an on-site comment naming this change; it remains in
`flake.nix` (`vmTests`) for local iteration. The parking policy itself is
codified in the `ci-workflows` spec delta: exclusions must reference an
open tracking change, and every non-parked suite must pass.

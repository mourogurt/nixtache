# Tasks

- [x] 1. Park the suite (design D4)
  - [x] 1.1 Remove `ab-ota-anywhere-vm` from the `vmtests.yml` matrix
        with a comment referencing this change; keep it in `flake.nix`
  - [x] 1.2 Add the parking policy requirement to the `ci-workflows`
        spec delta (exclusions reference an open change; non-parked
        suites must pass)
- [ ] 2. Rework the install leg to no-eval closure transport (design D3)
  - [ ] 2.1 Verify the pinned nixos-anywhere CLI accepts pre-built
        closure store paths; record the verdict (and the exact
        invocation) in the suite header
  - [ ] 2.2 If the CLI cannot: drive kexec + disko + closure transfer +
        `nixos-install` directly, mirroring nixos-anywhere's
        `tests/from-nixos.nix`; interpolate every path from the test's
        single CA-context evaluation
  - [ ] 2.3 Keep the first-boot (fresh QEMU + OVMF → UKI) and first-OTA
        legs unchanged; only the install mechanism changes
  - [ ] 2.4 Rewrite the suite header's hermeticity paragraph to the new
        contract ("no in-VM nix evaluation/build; wire steps over
        pre-built paths") and drop the stale hash-match rationale
- [ ] 3. Verify and un-park
  - [ ] 3.1 Full local run green (build + all assertions)
  - [ ] 3.2 Re-add `ab-ota-anywhere-vm` to the matrix; CI dispatch green
- [ ] 4. Documentation (per repo rule)
  - [ ] 4.1 Update `doc/technical_details/testing.md`: the suite's
        post-rework mechanics and the matrix parking policy, linking
        this change and the `ab-ota` spec
  - [ ] 4.2 Update the README repository map only if the suite's
        description changes materially

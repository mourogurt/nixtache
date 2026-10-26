# Tasks

## 1. Docs private-input access

- [x] 1.1 Extend `tests/ci-workflow-drift.nix` with docs-specific assertions for lock-derived SSH hosts, the optional `flake` credential bundle, and `ssh-setup` ordering before `generate-docs`; run `nix build .#checks.x86_64-linux.ci-workflow-drift` and confirm the new assertions fail against the pre-fix workflow.
- [x] 1.2 Add host derivation and `ssh-setup` with `creds: flake` to `.forgejo/workflows/docs.yml` after both checkouts and before `generate-docs`, preserving existing inputs, artifacts, sandbox probing, and missing-credential fallback; verify `nix build .#checks.x86_64-linux.ci-workflow-drift && cat ./result` passes and reports the new assertions.
- [x] 1.3 Update `doc/technical_details/workflow-mechanics.md`, `doc/technical_details/module-ci-wiring.md`, `doc/technical_details/testing.md`, and `doc/user_guide/docs-generation.md` for docs private-input fetching, `flakeSshCreds`, known-host coverage, and the expanded drift suite, with links to `openspec/specs/ci-workflows/spec.md`; verify the documented behavior and links match the workflow and `git diff --check` passes. Leave `README.md` unchanged because its existing workflow and test inventories remain accurate.

## 2. Integration validation

- [x] 2.1 Run `nix flake check --show-trace --all-systems` and confirm every check passes.
- [ ] 2.2 Run the reusable docs workflow for a caller with a private SSH input whose locked revision is absent from the runner cache; verify the input is fetched without a public-key error and the docs artifact is uploaded.

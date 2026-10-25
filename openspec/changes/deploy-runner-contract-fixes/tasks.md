# Tasks

## 1. Deploy gate and manual-user contracts

- [ ] 1.1 Replace the serve prefix match in `modules/deploy-target/user.nix` with exact validated forms and direct fixed-argv exec; extend `tests/deploy-target.nix` with accepted-form checks and rejection of `;`, `&&`, redirection, substitution and extra arguments — verify the deploy-target suite in CI and confirm valid `nix copy` transport
- [ ] 1.2 Move manual pointer-group membership to `users.groups.nixtache-deploy.members` and keep auto-provisioned users unchanged; assert the exact missing-user diagnostic, manual membership and existing warnings — verify `autoProvision = false` no longer fabricates `users.users.<name>` in the deploy-target suite
- [ ] 1.3 Reconcile `doc/user_guide/deploy.md` security wording and module descriptions with exact serve validation and manual membership, retaining links to `openspec/specs/deploy-user/spec.md` — verify the documented protocol lists only approved forms

## 2. Fresh probes and early artifacts

- [ ] 2.1 Generate a per-invocation unique probe name and pass it through `builtins.getEnv` in `.forgejo/actions/sandbox-probe/action.yml`; add a lightweight twice-run harness proving distinct outputs/fresh builders and retain `SANDBOX_OK` fallback behavior — verify the fixed output name is gone
- [ ] 2.2 Create `artifacts/` immediately after checkouts in `nix-check.yml` and `update-flake.yml`, before host derivation/SSH/probe; extend `tests/ci-workflow-drift.nix` to pin ordering and the defensive validation mkdir — verify early setup failure leaves an uploadable directory
- [ ] 2.3 Update `doc/technical_details/sandboxing.md` and `workflow-mechanics.md` with fresh-per-run and early-artifact semantics, linked to `openspec/specs/ci-workflows/spec.md` — verify no text claims cache can prove runtime sandbox health

## 3. Slow-fill cache coalescing

- [ ] 3.1 Add `proxy_cache_lock_age = 300s` beside the existing lock/read timeouts in both nginx locations; extend `tests/runner.nix` to pin all three directives and preserve cache-off behavior — verify the runner suite in CI
- [ ] 3.2 Add a non-KVM integration check with local nginx and a 30-second slow upstream: concurrent identical NAR requests must cause one upstream request and all clients must receive the fill; register the check in `flake.nix` and `doc/technical_details/testing.md` — verify its report in CI without an AB/CA suite
- [ ] 3.3 Update `doc/technical_details/binary-cache-availability.md` and cache option descriptions with the configured bounded coalescing semantics, linked to `openspec/specs/runner-cache/spec.md` — verify no stale default-lock-age claim remains

## 4. Complete self-CI failure reporting

- [ ] 4.1 Give validation an id + `continue-on-error`, run suite reporting with `if: always()`, derive the registered suite list when evaluable, and make the loop collect failures while printing every obtainable report before exiting — verify later suites still run after an injected earlier failure
- [ ] 4.2 Extend `tests/ci-workflow-drift.nix` with the validation-outcome/always-run wiring and a fake-suite failure case proving collected status remains non-zero — verify the workflow drift suite in CI
- [ ] 4.3 Update `doc/technical_details/testing.md` and `workflow-mechanics.md` with failure-collection and dynamic suite-inventory behavior, linked to `openspec/specs/docs/spec.md` — verify the docs no longer imply fail-fast report suppression

## 5. Integration

- [ ] 5.1 Run `openspec validate deploy-runner-contract-fixes --strict` and `openspec validate --specs --strict`; run the affected deploy-target, runner, cache and ci-workflow-drift suites in CI without any local AB/CA rebuild — verify all are green
- [ ] 5.2 Review the final diff for scope separation from `server-ab-migration-prep` and `wipe-on-cutover`, confirm docs/tasks cover every changed surface, and verify `git diff --check` — record any remaining blocker before review

## Workflow follow-up

- Archive the change after review and successful implementation (`/opsx-archive`).
- Verify the archived result and sync only its own deltas.

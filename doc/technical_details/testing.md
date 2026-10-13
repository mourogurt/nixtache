# Testing & coverage

How nixtache is tested, what "coverage" means for a declarative NixOS module
flake (spoiler: not line-coverage), and the rules every change must follow.

> Implementation of the coverage gate itself is tracked separately — this
> document fixes the **approach and contract** so the implementation has a
> target to land against.

---

## Testing strategy: pure-evaluation scenarios

nixtache's tests are **pure-evaluation** — they never boot a VM or container.
Each scenario evaluates a `nixosSystem` (or calls a lib helper) with specific
option values and asserts on the resulting `config.*` attributes (services
present, envs wired, caps granted, mounts/BindPaths, assertions firing) or on
the produced derivation's behaviour (build succeeds / fails).

Why pure-eval: fast (no VM), deterministic, runs in `nix flake check`, and
sufficient for a module whose job is to produce NixOS config attrsets. Runtime
behaviour of the container (does `nix-daemon-custom` actually start?) is out of
scope here and belongs to NixOS VM tests if ever needed.

### Layout — pure-eval suites (`checks.*`, built by every `nix flake check`)

| File | Covers | Wired as |
|---|---|---|
| `tests/runner.nix` | the runner module (`services.nixtache.runner.*`) — store `/`/`/srv`/empty, multi-instance, optional SSH creds, sandbox cap on/off, deploy map wiring, `runner.envs` | `checks.<system>.runner` |
| `tests/deploy-target.nix` | the target side — apply unit, deploy user, polkit, health check, rollback wiring | `checks.<system>.deploy-target` |
| `tests/ab-image.nix` | build-time A/B image config — fixed vs max-disk sizing, Verify | `checks.<system>.ab-image` |
| `tests/ab-existing.nix` | conformance of the implemented ab-image / deploy-target wiring (image layout, transfers, verify) | `checks.<system>.ab-existing` |
| `tests/ab-contract.nix` | wiring + assertion contracts for ab-provision / overlay-nix / runner store modes | `checks.<system>.ab-contract` |
| `tests/auto-update.nix` | the auto-update module — methods, assertions, timer/reboot wiring | `checks.<system>.auto-update` |
| `tests/ab-deploy-drift.nix` | the deploy action's protocol-drift skip contract (extracted action.yml text vs a fake old SSH gate) | `checks.<system>.ab-deploy-drift` |
| `tests/mkDocs.nix` | `lib/mkDocs.nix` — the `docStrictMode` 2×2 matrix (flag × all-documented) + prefix-filtering | `checks.<system>.mkDocs` |

(`tests/ab-fixture.nix` and `tests/ab-anywhere-install.nix` are shared
fixtures/helpers, not suites.)

### Layout — KVM-only VM suites (`vmTests.x86_64-linux`, NOT a checked output)

`nix flake check` skips `vmTests` entirely: the nspawn CI runner cannot chew
through QEMU suites, so they carry `requiredSystemFeatures = [ "kvm" ]` and
run in CI via [`.forgejo/workflows/vmtests.yml`](../../.forgejo/workflows/vmtests.yml)
on a KVM-capable runner (label `kvm`): `workflow_dispatch` (full matrix or a
smoke subset) + a weekly-full / nightly-smoke schedule. Full inventory:

`ab-deploy`, `ab-ota-e2e`, `ab-ota-e2e-erofs`, `ab-ota-e2e-none`,
`ab-ota-e2e-percent`, `ab-ota-anywhere-vm`, `ab-vm`, `ab-provision-vm`,
`overlay-nix-vm`, `overlay-nix-install-vm`, `overlay-nix-ab-swap-vm`,
`overlay-nix-ota-invalid-vm` (+ `-wipe`/`-reconcile`/`-reconcile-degraded`/
`-tmpfs` variants), `ab-ota-rollback-vm`, `ab-ota-noop-vm`,
`ab-ota-interrupted-vm`, `ab-ota-migrate-vm`, `runner-store-mode-vm`,
`ab-runner-compat-vm`, `ab-compression-vm`, `ab-staging-vm`,
`ab-deploy-self-vm`, `ab-ota-verify-vm`, `auto-update-vm`.

Every overlay test names its lower-DB world (see
[`doc/user_guide/overlay-nix.md`](../user_guide/overlay-nix.md)): the
`ota-invalid` suite CONSTRUCTS the delta-upper world (validity seeded via
`nix-store --load-db`), while `overlay-nix-install-vm` runs against a
host-store lower with a real database — results do not transfer between
worlds.

**Known red (pre-existing, verified on clean `fa1284a`)**: `ab-ota-anywhere-vm`
and the C4 leg of `ab-ota-verify-vm` time out on the current nixpkgs: the
remote trigger unit (`systemd-sysupdate update --reboot`) settles into a
green no-op after the booted-version assessment ("Newest installed version
matches booted version") instead of discovering the staged update, and a
manual plain update reports `Signature verification failed` against the
action-signed manifest. Both predate the ota-stabilization change (whose
+tries filename work leaves their failure mode unchanged); fixing them is
tracked separately.

Every test file is a function `{ nixpkgs, self, system }:` returning a
`pkgs.runCommand` derivation. Its builder prints a human-readable report (one
`ok`/`FAIL` line per check) into `$out` and exits non-zero on any failure — so
`nix build .#checks.<system>.<suite> && cat ./result` shows the whole matrix.

A new pure-eval test file MUST be registered in `flake.nix`; a new VM suite
goes into `vmTests.x86_64-linux` (never into `checks`):
```nix
checks.${system} = {
  runner = import ./tests/runner.nix { inherit nixpkgs self system; };
  # ...
};
vmTests.x86_64-linux.my-suite = import ./tests/my-suite.nix { inherit nixpkgs self; system = "x86_64-linux"; };
```

### Scenario shape (runner tests)

```nix
# Build a host with specific options, then assert on its evaluated config.
hostSrv = mkHost "/srv" { };
svcSrv  = hostSrv.config.containers."runner".config.systemd.services;
scenarioSrv = {
  name = "store.path=\"/srv\" relocates the store; SSH off → no key wiring";
  checks = {
    hasCustomDaemon  = has svcSrv "nix-daemon-custom";
    giteaBindPaths   = svcSrv."gitea-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
    noLoadCredential = loadCred svcSrv == [ ];
    hasSandboxCap    = lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities;
  };
};
```
A scenario is `{ name, checks }`; the suite is `scenarios = [ ... ]`; the runCommand
fails iff any check is false.

### Build-failure assertions (mkDocs tests)

Pure-eval catches eval-time throws (e.g. failed assertions via `builtins.tryEval`)
but NOT build-time failures. For cases that must FAIL TO BUILD (e.g.
`docStrictMode = true` + an undocumented option rejects the `nixosOptionsDoc`
build), the pattern is:

- cases that **must build** → referenced as real deps of the test derivation
  (their `outPath` is interpolated in the builder, forcing Nix to build them;
  any failure fails the test);
- the case that **must fail** → only its `.drvPath` is passed in (a string, not
  a dep, so its build failure does not propagate); the test then verifies the
  *preconditions* at eval time (the undocumented option exists) and documents
  the expected build failure. The strict-build mechanism itself is independently
  exercised by nixtache's own `packages.optionsMarkdown` (strict by default).

---

## Rules (also in AGENTS.md)

1. **Every `mkOption` MUST have a `description`.** Enforced in CI:
   `nixosOptionsDoc` for this flake's own `packages.optionsMarkdown`/`JSON`/`HTML`
   runs with `warningsAreErrors = true`, so an undocumented option BREAKS the
   docs build. (`mkEnableOption` auto-generates one, so it's exempt.) Consumers
   opt into the same strictness via `nixtache.lib.mkDocs { docStrictMode = true; }`.

2. **Every option MUST be covered by a test.** An option without a test is
   unfinished. When you add an option or change behaviour, add/extend a
   scenario in `tests/` and run `nix build .#checks.<system>.<suite>`.

---

## What "coverage" means for Nix

Nix is a declarative, pure-functional config language — there is no runtime
execution path, so **classic line-coverage (`coverage.py` / `gcov` / Istanbul)
does not apply**. No tool measures "X% of Nix lines executed". Quoting a number
like "85% line coverage" for a `.nix` module is meaningless.

The meaningful analog for a NixOS module is **option-coverage** + **branch-coverage**:

### Option-coverage

> Fraction of declared `mkOption` paths exercised by at least one test scenario.

- **Declared** = every option under `services.nixtache.runner.*` (and, for
  `lib/`, every parameter of `mkDocs`), enumerated via
  `lib.optionAttrSetToDocList <eval>.options`.
- **Exercised** = some scenario sets the option to a non-default value AND/OR
  asserts on the resulting `config.*` it influences. Tracked explicitly via a
  `covers` list per scenario (accurate, needs annotation) or heuristically via
  grepping option names across the test files (zero-annotation, less precise).

### Branch-coverage

> Each `mkIf` / `mkMerge` branch is taken by at least one scenario.

For nixtache the meaningful branches: `store.path == "/"` vs relocated;
`enableSandbox` true/false; `flakeSshCreds`/`updateSshCreds` null vs set;
`instances` single vs multi; `cache.enable` true/false. Most of these are
already scenario-paired in `tests/runner.nix`.

### Threshold & gate (target, implementation tracked separately)

- A `checks.<system>.coverage` derivation computes
  `|∪ scenario.covers| / |declared options|`, prints uncovered options, and
  fails when the ratio is below the threshold.
- Threshold: start at whatever the current explicit-coverage yields, ratchet up
  toward ≥ 85% as scenarios gain `covers` annotations. Never lower it.
- Uncovered options are reported by name so the gap is actionable, not just a
  failing percentage.

This is an **option-coverage** gate, honestly named — not a line-coverage claim.

---

## Running tests

```bash
# Everything (evaluates + builds all checks + packages):
nix flake check --show-trace --all-systems

# One pure-eval suite, with the printed report:
nix build .#checks.x86_64-linux.runner && cat ./result
nix build .#checks.x86_64-linux.mkDocs && cat ./result

# A KVM VM suite (KVM host only; CI runs them via vmtests.yml):
nix build .#vmTests.x86_64-linux.ab-deploy
nix build .#vmTests.x86_64-linux.overlay-nix-vm

# (future) coverage report:
nix build .#checks.x86_64-linux.coverage && cat ./result
```

### Provisioning a KVM runner for `vmtests.yml`

The workflow's `kvm`-labelled runner needs two things the default nspawn CI
runner lacks (the runner module propagates the host's
`nix.settings.system-features` into job environments, so both are host-side):

```nix
# on the KVM runner host (e.g. a QEMU VM on the zen3 cluster):
nix.settings.system-features = [ "kvm" "nixos-test" "big-parallel" ];
# expose /dev/kvm to the runner's nspawn container:
containers.<runner-name>.bindMounts."/dev/kvm" = {
  hostPath = "/dev/kvm";
  isReadOnly = true;
};
```

`kvm` + `nixos-test` are the `requiredSystemFeatures` the suites declare
(`runNixOSTest` adds both itself; the pexpect-based suites declare `kvm`).
Register the runner instance with the `kvm` label in Forgejo so the workflow
resolves it. If the runner is itself a VM, enable nested virtualization
(`kvm-amd nested=1`, default on modern kernels) — or prefer
containers-on-bare-metal to skip nesting entirely.

In CI (`ci.yml`) `nix flake check` runs on push/PR to `main`, then an
explicit `nix build` loop prints each `checks.x86_64-linux.<suite>` report
(runner, deploy-target, ab-image, mkDocs, ab-existing, ab-contract,
auto-update, ab-deploy-drift) to the job log, and the `nixtache-options` docs artifact is
generated.

---

## Adding a new option or test — checklist

1. **Declare** the option with a `description` (mandatory — CI enforces it).
2. **Add a scenario** in the relevant `tests/*.nix` that sets the option to a
   non-default value and asserts on the resulting `config.*`. Add the opposite
   value too if the option has a meaningful off-branch.
3. **Annotate** the scenario's `covers = [ "services.nixtache.runner.<opt>" ]`
   (once the coverage gate lands) so the option counts toward coverage.
4. **Run** `nix build .#checks.<system>.<suite>` and read the report.
5. If the option belongs to a new area, create a new `tests/<area>.nix` and
   wire it into `flake.nix` `checks.<system>`.

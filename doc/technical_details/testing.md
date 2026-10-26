# Testing & coverage

How nixtache is tested, what "coverage" means for a declarative NixOS module
flake, and the rules every change must follow. Documentation requirements:
[`openspec/specs/docs/spec.md`](../../openspec/specs/docs/spec.md).

## Testing strategy

`checks.<system>` contains fast eval-oriented suites. Each scenario evaluates
a `nixosSystem` (or calls a lib helper) with specific option values and asserts
on the resulting `config.*` attributes or on a small derivation's build
behavior. These checks run in every `nix flake check`.

`vmTests.x86_64-linux` contains the runtime layer: NixOS VM tests that boot
machines and containers and verify behavior such as daemon startup, OTA slot
swaps and overlay repairs. These suites require KVM and are built explicitly,
not by `nix flake check`.

### Layout — eval-oriented suites (`checks.*`)

| File | Covers | Wired as |
|---|---|---|
| `tests/runner.nix` | the runner module (`services.nixtache.runner.*`) — store `/`/`/srv`/empty, multi-instance, optional SSH creds, sandbox cap on/off, deploy map wiring, `runner.envs` | `checks.<system>.runner` |
| `tests/deploy-target.nix` | the target side — apply unit, deploy user, polkit, health check, rollback wiring | `checks.<system>.deploy-target` |
| `tests/ab-image.nix` | build-time A/B image config — fixed vs max-disk sizing, Verify, store-tree imaging | `checks.<system>.ab-image` |
| `tests/ab-contract.nix` | cross-module A/B contracts — provisioning, overlay cutover ordering and marker independence, runner store modes | `checks.<system>.ab-contract` |
| `tests/overlay-nix.nix` | the overlay-nix module — `upperOnUpdate` enum (wipe/reconcile), default, lifecycle wiring | `checks.<system>.overlay-nix` |
| `tests/ab-existing.nix` | compression/UKI options, runner A/B staging assertions and retain-GC wiring, `hostBackup`, `deploy-target.ab.forceAfterTimeout`, native-store/A/B assertion | `checks.<system>.ab-existing` |
| `tests/auto-update.nix` | the auto-update module — methods, assertions, timer/reboot wiring | `checks.<system>.auto-update` |
| `tests/ab-deploy-drift.nix` | the deploy action's protocol-drift skip contract (extracted action.yml text vs a fake old SSH gate) | `checks.<system>.ab-deploy-drift` |
| `tests/ci-workflow-drift.nix` | the workflows' sandbox-probe ordering contract and vmtests flag wiring | `checks.<system>.ci-workflow-drift` |
| `tests/mkDocs.nix` | `lib/mkDocs.nix` — the `docStrictMode` flag × documentation-completeness matrix | `checks.<system>.mkDocs` |

`tests/ab-fixture.nix`, `tests/ab-anywhere-install.nix` and
`tests/ab-ota-vm-lib.nix` are shared fixtures/helpers, not registered suites.

### Layout — KVM-only VM suites (`vmTests.x86_64-linux`)

VM suites carry `requiredSystemFeatures = [ "kvm" ]` and run in CI via
[`.forgejo/workflows/vmtests.yml`](../../.forgejo/workflows/vmtests.yml) on a
KVM-capable runner (label `kvm`): manual full/smoke dispatch plus weekly-full
and nightly-smoke schedules. Full inventory:

`ab-deploy`, `ab-ota-e2e`, `ab-ota-e2e-erofs`, `ab-ota-e2e-none`,
`ab-ota-e2e-percent`, `ab-ota-anywhere-vm`, `ab-vm`, `ab-provision-vm`,
`overlay-nix-vm`, `overlay-nix-install-vm`, `overlay-nix-ab-swap-vm`,
`overlay-nix-ota-invalid-vm` (+ `-wipe`/`-reconcile`/`-reconcile-degraded`/
`-tmpfs` variants), `ab-ota-rollback-vm`, `ab-ota-noop-vm`,
`ab-ota-interrupted-vm`, `ab-ota-migrate-vm`, `ab-ota-migrate-boot-vm` (+
`-override` variant), `ab-data-pool-vm`, `runner-store-mode-vm`,
`runner-store-swap-clone-vm`, `runner-store-swap-overlay-vm`,
`ab-runner-compat-vm`, `ab-compression-vm`, `ab-staging-vm`,
`ab-deploy-self-vm`, `ab-ota-verify-vm`, `auto-update-vm`.

The migrate pair splits the migration contract:
`ab-ota-migrate-vm` pins the live side (provisioning, idempotency, update
machinery ready, live closure retained) and deliberately never boots the
staged image; `ab-ota-migrate-boot-vm` boots a legacy-labeled disk through
the first OTA cutover — unarmed staging does not cut over, wrong labels roll
back safely, and relabeled partitions or forced `fileSystems` devices cut
over with signed staging throughout.

Overlay tests distinguish their lower-DB worlds (see
[`doc/user_guide/overlay-nix.md`](../user_guide/overlay-nix.md)): appliance
suites use the DB shipped in the image, while `overlay-nix-install-vm` uses a
host-store lower with its own database. Results do not transfer between those
worlds. Faithful store imaging is pinned by `checks.ab-image` (a store tree
containing a symlink path) and `overlay-nix-vm` (the symlink survives imaging
and resolves through `nix path-info`).

The `overlay-nix-ota-invalid` matrix covers empty and tampered update attempts,
same-version persistent-upper reboots, live-root reconcile, degraded reconcile
retry with independent lower-DB/lifecycle markers, and same-version tmpfs
reset/reseed. `overlay-nix-ab-swap-vm` and `overlay-nix-install-vm` retain the
default-wipe swap and non-appliance installation contracts.

### Pure-eval suite and scenario shape

A registered pure-eval suite returns a report derivation whose builder prints
one `ok`/`FAIL` line per check and exits non-zero on failure. Its arguments
depend on the suites it evaluates; shared helpers can instead return attrsets,
and VM suites use the NixOS test runner. Build a report with:

```bash
nix build .#checks.x86_64-linux.runner && cat ./result
```

A new pure-eval test file MUST be registered in `flake.nix`; a new VM suite
goes into `vmTests.x86_64-linux`, never into `checks`:

```nix
checks.${system} = {
  runner = import ./tests/runner.nix { inherit nixpkgs self system; };
};
vmTests.x86_64-linux.my-suite = import ./tests/my-suite.nix {
  inherit nixpkgs self;
  system = "x86_64-linux";
};
```

Runner scenarios evaluate a host and assert on its configuration:

```nix
hostSrv = mkHost "/srv" { services.nixtache.runner.enableSandbox = false; };
svcSrv = servicesOf hostSrv;
scenarioSrv = {
  name = "store.path=\"/srv\" relocates the store; SSH off → no key wiring";
  checks = {
    hasCustomDaemon = has svcSrv "nix-daemon-custom";
    forgejoBindPaths = svcSrv."forgejo-runner-default".serviceConfig.BindPaths == [ "/srv/nix:/nix" ];
    noSshLoadCredential =
      !(hasCredPrefix "flake_ssh_" (loadCred svcSrv)
        || hasCredPrefix "update_ssh_" (loadCred svcSrv));
    noSandboxCap = !(lib.elem "CAP_SYS_ADMIN" hostSrv.config.containers."runner".additionalCapabilities);
    hasIpcLock = lib.elem "CAP_IPC_LOCK" hostSrv.config.containers."runner".additionalCapabilities;
  };
};
```

A scenario is `{ name, checks }`; the suite aggregates `scenarios = [ ... ]`
and fails iff any check is false.

### Build-failure assertions (mkDocs tests)

Pure eval catches eval-time throws (for example, failed assertions through
`builtins.tryEval`) but not build-time failures. The `mkDocs` suite handles
the strict-mode matrix as follows:

- cases that must build are interpolated into the test builder, making them
  real dependencies whose failures fail the test;
- the strict + undocumented case is not referenced by the builder at all —
  even a `.drvPath` reference would make `nix flake check` reach the failing
  options build. The suite verifies its eval-time precondition (an
  undocumented option exists), while nixtache's own strict
  `packages.optionsMarkdown` build exercises the rejection mechanism.

## Rules (also in AGENTS.md)

1. **Every `mkOption` MUST have a `description`.** Enforced in CI:
   `nixosOptionsDoc` for this flake's own `packages.optionsMarkdown`/`JSON`/`HTML`
   runs with `warningsAreErrors = true`, so an undocumented option breaks the
   docs build. (`mkEnableOption` auto-generates one, so it's exempt.) Consumers
   opt into the same strictness via `nixtache.lib.mkDocs { docStrictMode = true; }`.
2. **Every option MUST be covered by a test.** When adding an option or
   changing behavior, add or extend a scenario in `tests/` and run
   `nix build .#checks.<system>.<suite>`.

## What "coverage" means for Nix

Classic line-coverage does not describe a declarative module's behavior. The
useful measures are:

- **Option coverage:** every consumer-facing option under
  `services.nixtache.*` (and every `lib.mkDocs` parameter) is set to a
  non-default value and/or has its resulting configuration asserted.
- **Branch coverage:** every meaningful configuration branch is exercised.
  Runner examples include native vs relocated stores, sandbox on/off,
  optional credential bundles, single vs multiple instances and cache on/off;
  the sibling modules have their own method, policy and failure branches.

## Running tests

```bash
# Evaluate flake outputs and build all checks:
nix flake check --show-trace --all-systems

# One pure-eval suite, with the printed report:
nix build .#checks.x86_64-linux.runner && cat ./result
nix build .#checks.x86_64-linux.mkDocs && cat ./result

# KVM VM suites (CI runs them via vmtests.yml):
nix build .#vmTests.x86_64-linux.ab-deploy
nix build .#vmTests.x86_64-linux.overlay-nix-vm
```

### Provisioning a KVM runner for `vmtests.yml`

The workflow's `kvm`-labelled runner needs host-side system features and
access to `/dev/kvm` inside the runner container:

```nix
nix.settings.system-features = [ "kvm" "nixos-test" "big-parallel" ];
containers.<runner-name>.bindMounts."/dev/kvm" = {
  hostPath = "/dev/kvm";
  isReadOnly = true;
};
```

`runNixOSTest` adds the `kvm` and `nixos-test` requirements; pexpect-based
suites declare `kvm` themselves. Give the runner instance the `kvm` label so
`runs-on: kvm` resolves:

```nix
services.nixtache.runner.instances.kvm = {
  uuid = "…";
  tokenFile = config.sops.secrets.runner-token-kvm.path;
  labels = [ "kvm:host" ];
};
```

If the runner is itself a VM, enable nested virtualization or prefer
containers on bare metal.

Self-CI (`ci.yml`) runs on pushes to `main`, all pull requests and manual
dispatch. It runs `nix flake check`, prints each
`checks.x86_64-linux.<suite>` report, and generates the `nixtache-options`
artifact.

## Adding a new option or test — checklist

1. Declare the option with a `description`.
2. Add a scenario that sets the option and asserts its resulting `config.*`;
   add the opposite value too if it has a meaningful off-branch.
3. Run `nix build .#checks.<system>.<suite>` and read the report.
4. If the option belongs to a new area, create `tests/<area>.nix` and register
   it in `flake.nix` under `checks.<system>` (or `vmTests.x86_64-linux` for a
   KVM suite).

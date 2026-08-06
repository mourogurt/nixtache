# IMPLEMENTATION-PLAN — поэтапная реализация direct-deploy

> Roadmap по `0001-direct-deploy.md` §11 + решениям из `REVIEW-ISSUES.md`
> (B1/B2/S1–S5/M1–M3). Порядок A→B→C→D→E→F (E/F включены по решению пользователя).
> Дата: 2026-08-06.

## Политика checkpoints

Правки контракта runner-модуля (`modules/runner/*`) и critical security-relevant
настроек — **критичные**. Перед каждым батчем: конкретный план файлов + тестов →
подтверждение → реализация → `nix flake check` + `nix build .#checks.*` →
только потом следующий батч. Код не льётся одним коммитом через все батчи.

## Граф зависимостей (исправленный под V2)

> **V2-пивот:** активация переведена на systemd (`nixtache-apply.service` +
> polkit), deploy-rs выкинут, зоопарк sudo/doas/run0 исчез. См. `REVIEW-ISSUES.md`
> §«V2-пивот». Батч A и B (без deploy-rs) — независимые фундаменты, можно
> параллельно. C упрощается (нет `mkDeployNodes`, action делает `nix copy` +
> `systemctl start`).

```
A — runner map contract (Stage 1 + S1)         ─┐
   (types/deploy.nix/instances refactor)         │
                                                 ├─→ C — action deploy-target + workflow deploy.yml
B — приёмный модуль deploy-target (V2)          ─┘    (nix copy + systemctl start nixtache-apply; B1 probe внутри юнита)
   (apply.service + polkit + health-check)            │
                                                       ▼
                                                D — consumer wiring (end-to-end smoke)
                                                       │
                                                       ▼
                                       E — ab-image (server chicken-and-egg)
                                       F — cross-arch (aarch64 и т.п.)
```

A и B **не зависят друг от друга**. C требует оба. D требует A+B+C.

---

## Батч A — runner map contract  ✅ РЕАЛИЗОВАН

**Скоуп:** карта целей `services.nixtache.runner.deploy.targets` → env
`NIXTACHE_DEPLOY_TARGETS` + LoadCredential ключей. Только runner-side, ноль
зависимостей от других батчей.

| Файл | Действие | Что |
|---|---|---|
| `modules/runner/types.nix` | ✅ | `deployTargetType` (submodule: `enable`, `host`, `sshUser`, `sshPort`, `method="live"\|"ab-image"`, `sshPrivateKey`, `sshPublicKey`, `system`, `extraOptions`, `tags`, `timeout`). **Без `buildHost`, без `transport`** (V2) |
| `modules/runner/instances.nix` | ✅ (S1) | `_extraRunnerEnvs` (`attrsOf str`, internal) + merge в `runner.envs` |
| `modules/runner/deploy.nix` | ✅ **новый** | `deploy.targets` опция + env/LoadCredential wiring (transport убран из JSON) |
| `modules/runner/default.nix` | ✅ | `imports += [ ./deploy.nix ]` |
| `tests/runner.nix` | ✅ | +6 сценариев: пустая карта / с ключами / `sshPrivateKey=null` / `method=ab-image` / `method=live` default / `_extraRunnerEnvs` агрегация |

**Verify:** `nix flake check` — all checks passed; 78 ok в runner-test.

**Deps:** нет.

---

## Батч B — приёмный модуль `deploy-target` (V2)  ✅ РЕАЛИЗОВАН

**Скоуп:** `nixosModules.deploy-target` — импортируется каждым таргетом.
Активация через root-юнит `nixtache-apply.service` (set+switch+probe+rollback,
B1) + polkit + pointer-dir; Tier-0 boot-time health-check; deploy-user
provisioning. **Никакого sudo/doas/run0** (V2). Независим от A.

| Файл | Действие | Что |
|---|---|---|
| `modules/deploy-target/options.nix` | ✅ **новый** | `services.nixtache.deploy-target.{enable, criticalUnits, healthCheckTimeout, deployUser{name,authorizedKey,autoProvision}}` (без `transport` — V2) |
| `modules/deploy-target/user.nix` | ✅ **новый** | deploy-user + authorizedKey + `nixtache-deploy` group membership (+ assert если `autoProvision=false`) |
| `modules/deploy-target/apply.nix` | ✅ **новый** | `nixtache-apply.service` (root: read pointer → set profile → switch → probe criticalUnits → rollback on fail), polkit-правило на `systemctl start nixtache-apply.service`, `nixtache-deploy` group + `/var/lib/nixtache` StateDirectory |
| `modules/deploy-target/health-check.nix` | ✅ **новый** | Tier-0 `nixtache-health-check.service` (`Before=`+`RequiredBy=` `boot-complete.target`, окно `healthCheckTimeout`) |
| `modules/deploy-target/default.nix` | ✅ **новый** | orchestrator (imports) |
| `flake.nix` | ✅ | `nixosModules.deploy-target` + `checks.x86_64-linux.deploy-target` |
| `tests/deploy-target.nix` | ✅ **новый** | 5 сценариев, 22 check (apply+polkit / criticalUnits / empty / default timeout / autoProvision=false assertion) |

**Verify:** `nix flake check` — all checks passed; 22 ok в deploy-target-test;
`nix build .#optionsMarkdown` strict-mode зелёный (все опции с description).

**Open decisions:** нет — PE-тул не выбирается (нет escalation-тула вообще).

**Deps:** нет (параллелен A).

---

## Батч C — action `deploy-target` + workflow `deploy.yml` (V2, упрощён)  ✅ РЕАЛИЗОВАН

**Скоуп:** action делает discovery → probe → `nix build toplevel` →
`nix copy --to ssh://deploy-user@host` → write pointer →
`ssh systemctl start nixtache-apply.service` (Tier-1 probe уже внутри юнита — B).
**Нет deploy-rs, нет mkDeployNodes, нет deploy-rs flake input.** Workflow —
reusable (`on: workflow_call`); consumer зовёт через (a) standalone или (b)
combined с nix-check (`build.uses: nix-check.yml` + `deploy.uses: deploy.yml` +
`needs: build`).

| Файл | Действие | Что |
|---|---|---|
| `.forgejo/actions/deploy-target/action.yml` | ✅ **новый** | composite: mode по event/branch → discovery (`nix flake show --json`) → опциональность-filters → SSH-probe (R5) → `_liveApply` (build+copy+pointer+`systemctl start`) / `_abImage` stub (до E); `HAS_SANDBOX_CAP`→`--no-sandbox` (M3); `NIX_SSHOPTS` для nix copy; artifacts-upload |
| `.forgejo/workflows/deploy.yml` | ✅ **новый** | reusable `on: workflow_call` + `workflow_dispatch`; job `deploy` → checkout caller + nixtache → `deploy-target` action |

**Verify:** `python3 yaml.safe_load` ✓ оба файла; `bash -n` ✓ встроенный скрипт;
`nix flake check` зелёный. End-to-end smoke — после Batch D (consumer wiring).

**Deps:** A (карта/env) ✅ + B (apply-юнит + polkit на таргете) ✅.

---

## Батч D — consumer wiring (nixos-configuration) — end-to-end

**Скоуп:** реальный integration. sops deploy-ключи, наполнение карты из
`common_secrets.network`, импорт приёмного модуля на desktop/laptop, тонкая
обёртка workflow. **Первый end-to-end smoke.**

| Файл (nixos-configuration) | Действие |
|---|---|
| `server/services/deploy-keys.nix` | **НОВОЕ**: sops `deploy-key-{desktop,laptop}`, наполнение `services.nixtache.runner.deploy.targets` (адреса из `common_secrets.network.amneziawg.nodes.*`) |
| `secrets/deploy-keys/{desktop,laptop}.ed25519` | **НОВОЕ** (age-encrypted) |
| `common/deploy-target.nix` | **НОВОЕ**: `imports = [ nixtache.nixosModules.deploy-target ]` + universal `criticalUnits` (consumer's choice — в reference workspace `wireguard-awg0.service`) + `deployUser` |
| `desktop/...`, `laptop/...` | правка: import `common/deploy-target.nix`, per-target overrides |
| `flake.nix` (nixos-configuration) | правка: `deploy = nixtache.lib.mkDeployNodes { deployLib = deploy-rs.lib.${system}; inherit (self) nixosConfigurations; targets = <map>; };` + `inputs.deploy-rs` |
| `server/services/forgejo-runner.nix` | правка: `hostPackages += [ deploy-rs ]` |
| `.forgejo/workflows/deploy.yml` | **НОВОЕ**: thin wrapper `jobs.deploy.uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main` |

**Verify (end-to-end smoke):**
1. PR → `dry-activate` автофайрится → desktop/laptop показывают diff без мутации.
2. merge в `main` → `switch` автофайрится → desktop/laptop активируются.
3. (rollback smoke) сломать `criticalUnits` в PR → Tier-1 probe ловит → revert.

**Deps:** A + B + C.

---

## Батч E — ab-image (server chicken-and-egg)

**Скоуп:** `method = "ab-image"` для server. CI stage'ит образ → host
`systemd-sysupdate` пишет неактивный слот → idle-gated reboot. Самый объёмный.

| Группа | Что |
|---|---|
| **nixtache runner-модуль** | `services.nixtache.runner.deploy.ab.*` (`enable`, `stagingPath`, `runnerHost`, `nginx.location`, `retain`); `forgejoPort` опция (S2); nginx vhost reuse `cache.domain`; `nixtache-ab-gc.{timer,service}` |
| **nixtache приёмный модуль** | `services.nixtache.deploy-target.ab.*` (`enable`, `gating`, `idleWaitTimeout`, `forceAfterTimeout`, `forgejoApiTokenFile`); gating-unit `nixtache-ab-apply.{path,service}` с `pathConfig.PathExists` (S3, исправлено) |
| **nixtache action** | `_abImage` ветка: build sysupdate-package → central-stage → apply по топологии (local-self vs remote) |
| **consumer (server)** | repart-слоты (`imports += [ "${nixpkgs}/nixos/modules/image/repart.nix" ]`, M2) + UKI + `systemd.sysupdate` transfers + boot-counting + `system.image.{id,version}` + подпись + Forgejo API token |
| **тесты** | `tests/runner.nix`: `ab.enable`→staging/nginx wired; `tests/deploy-target.nix`: `ab.gating`→gating-unit, assert sysupdate+bootCounting |

**Open decisions (на checkpoint E):** подпись образов (gpg/cosign/sigstore),
retain-политика GC, idle-wait таймауты.

**Verify:** smoke на disposable server (или VM с A/B-слотами).

**Deps:** D (нужна рабочая CI-deploy инфраструктура).

---

## Батч F — cross-arch

**Скоуп:** non-`x86_64` цели. binfmt-эмуляция на runner-host (приоритет) + опц.
`deploy.nodes.<name>.remoteBuild = true` для native-сборки на цели. `--build-host`
убран (S4).

| Файл | Действие |
|---|---|
| consumer runner-host | `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` |
| `lib/mkDeployNodes.nix` | правка: проброс опц. `remoteBuild` per-node |
| `tests/runner.nix` | цель `system="aarch64-linux"`; assert `buildHost` **отсутствует** в JSON |

**Verify:** smoke на aarch64-таргете (напр. RPi).

**Deps:** C (mkDeployNodes). Реально — отложить до появления aarch64-цели.

---

## Сводка объёма

| Батч | новых файлов | правок | репо | можно end-to-end smoke? |
|---|---|---|---|---|
| A | 1 (`deploy.nix`) | 3 (`types`, `instances`, `default`, `tests`) | nixtache | нет (только tests) |
| B | 4 (`deploy-target/*`) | 2 (`flake`, `tests`) | nixtache | нет (только tests) |
| C | 3 (`mkDeployNodes`, action, workflow) | 1 (`flake`) | nixtache | нет (нужен consumer) |
| D | 4 (consumer) | 3 | nixos-configuration | **да** (desktop/laptop) |
| E | ~3 + consumer prep | ~5 | оба | да (server) |
| F | 0–1 | 2 | оба | да (aarch64) |

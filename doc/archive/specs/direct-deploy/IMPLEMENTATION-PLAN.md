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

## Батч D — consumer wiring (nixos-configuration) — end-to-end  ✅ РЕАЛИЗОВАН

**Скоуп:** реальный integration. sops deploy-ключи, наполнение карты из
`common_secrets.network`, импорт приёмного модуля на desktop/laptop, combined
pipeline (вариант b — `deploy` job в `nix-check.yml`, `needs: check-flake`).
**Никакого deploy-rs** (V2): карта + приёмный модуль + action `deploy-target`
уже делают всё через `nix copy` + root-юнит + polkit. **End-to-end smoke готов.**

| Файл (nixos-configuration) | Действие | Статус |
|---|---|---|
| `server/services/deploy-keys.nix` | **НОВОЕ**: sops `deploy-key-{desktop,laptop}` (binary, `secrets/deploy-key-*.enc`) + наполнение `services.nixtache.runner.deploy.targets` (адреса из `common_secrets.network.amneziawg.nodes.*`) | ✅ |
| `secrets/deploy-key-{desktop,laptop}.enc` | **НОВОЕ** (age-encrypted via `.sops.yaml`) | ✅ |
| `common/deploy-target.nix` | **НОВОЕ**: `imports = [ nixtache.nixosModules.deploy-target ]` + universal `criticalUnits = [ "wireguard-awg0.service" ]` + `healthCheckTimeout = 300` | ✅ |
| `desktop/services/deploy-target.nix`, `laptop/services/deploy-target.nix` | **НОВОЕ**: per-host `deployUser` (своя keypair на машину, реальный pubkey) + `autoProvision = true` | ✅ |
| `.forgejo/workflows/nix-check.yml` | правка: **combined pipeline (вариант b)** — добавлен `jobs.deploy` (`needs: check-flake`, `uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main`) вместо отдельного `deploy.yml` | ✅ |
| `{desktop,laptop,server}/hardware.nix` | `boot.loader.systemd-boot.bootCounting.enable = true` (consumer-side N1, подготовлено для Tier-0/ab-image) | ✅ |

> **deploy-rs НЕ используется:** в V2 его нет (ни `inputs.deploy-rs`, ни
> `hostPackages += [ deploy-rs ]`, ни `nixtache.lib.mkDeployNodes`). Активация —
> через root-юнит `nixtache-apply.service` + polkit на цели. См. `REVIEW-ISSUES.md`
> §«V2-пивот».

**Verify (end-to-end smoke):**
1. PR → `dry-activate` автофайрится (deploy job `needs: check-flake`) → desktop/laptop показывают diff без мутации.
2. merge в `main` → `switch` автофайрится → desktop/laptop активируются (deploy-юзер провижен, ключи в sops, polkit на старте apply-юнита).
3. (rollback smoke) сломать `criticalUnits` в PR → Tier-1 probe ловит внутри `nixtache-apply.service` → revert.

**Deps:** A + B + C. ✅

---

## Батч E — ab-image (server chicken-and-egg) — nixtache ✅ / consumer 📝

**Скоуп:** `method = "ab-image"` для server. CI stage'ит образ → host
`systemd-sysupdate` пишет неактивный слот → idle-gated reboot. Самый объёмный.

**Статус:** nixtache-сторона (модули + action + тесты) — ✅ реализована, `nix flake check`
зелёный, все ab-сценарии проходят. consumer-сторона (`nixos-configuration`) — 📝
написана, gated (`enable`/`buildAb`/`abReady` = false по умолчанию, inert), требует:
bump nixtache → `nixos-rebuild build` верификации → переустановки server с A/B-образа
(`nixos-anywhere`, деструктивно) → flip флагов → smoke. См. runbook в заголовке
`nixos-configuration/server/ab-image.nix`.

**Решения (checkpoint E, применены):**
- **Подпись:** GPG/OpenPGP (systemd-sysupdate верифит **только** GPG — захардкожено в
  апстриме, age/sops как подпись невозможны). Приватный ключ — age-encrypted sops-секрет
  (`ab.signingKeyFile`), CI подписывает `SHA256SUMS` → `SHA256SUMS.gpg` временным
  GNUPGHOME. Публичный ключ — `/etc/systemd/import-pubring.pgp` на таргете,
  `Transfer.Verify = yes`.
- **retain = 5**, **idleWaitTimeout = 1800**, **forceAfterTimeout = false** (дефолты).

| Группа | Что | Статус |
|---|---|---|
| **nixtache runner-модуль** | `modules/runner/ab.nix`: `services.nixtache.runner.deploy.ab.*` (`enable`, `stagingPath`, `runnerHost`, `nginx.location`, `retain`, `signingKeyFile`); `forgejoPort` опция (S2, default из `forgejoUrl`); staging bind-mount + nginx location (`autoindex on`) на cache-vhost + `nixtache-ab-gc.{timer,service}` + LoadCredential `sysupdate_signing_key` + gnupg в контейнере + env `NIXTACHE_RUNNER_HOST`/`NIXTACHE_AB_STAGE` | ✅ |
| **nixtache приёмный модуль** | `modules/deploy-target/ab.nix`: `services.nixtache.deploy-target.ab.*` (`enable`, `gating`, `idleWaitTimeout`, `forceAfterTimeout`, `forgejoApiTokenFile`); assert ab.enable→sysupdate+bootCounting, ab.gating→token; polkit на `start systemd-sysupdate`/`nixtache-ab-apply`; gating-unit `nixtache-ab-apply.{path,service}` (`pathConfig.PathExists`, S3) — idle-poll Forgejo API → sysupdate | ✅ |
| **nixtache action** | `_abImage` ветка: build `sysupdate-package` → central-stage (regen SHA256SUMS) → GPG-sign → apply по топологии (local-self: `touch ab-pending`+`start nixtache-ab-apply`; remote: `start systemd-sysupdate`) | ✅ |
| **тесты** | `tests/runner.nix`: +3 (ab staging/nginx/env/gc/gnupg/signing, forgejoPort, basename-assert); `tests/deploy-target.nix`: +4 (ab polkit, ab.gating path+service+script, assert no-sysupdate, assert gating-no-token) | ✅ |
| **consumer (server)** | `server/services/deploy-ab.nix` (runner-host staging + sops signing key + forgejo token, gated `enable`); `server/ab-image.nix` (repart A/B слоты + UKI + `systemd.sysupdate` transfers + `sysupdate-package` + `system.image.{id,version}` + pubring + deploy-target.ab + map entry, gated `buildAb`/`abReady`) | 📝 написан, gated, требует верификации + reinstall |

**Verify:** smoke на disposable server (или VM с A/B-слотами) — после bump nixtache +
reinstall. nixtache-тесты зелёные сейчас.

**Deps:** D (нужна рабочая CI-deploy инфраструктура) ✅.

**Verify:** smoke на disposable server (или VM с A/B-слотами).

**Deps:** D (нужна рабочая CI-deploy инфраструктура).

---

## Батч F — cross-arch

**Скоуп:** non-`x86_64` цели. binfmt-эмуляция на runner-host (единственный
механизм — V2 убрал `buildHost`/`--build-host`/`remoteBuild` и deploy-rs).
`nix build` (им пользуются и `_liveApply` для toplevel, и `_abImage` для
sysupdate-package) собирает cross-arch деривации в sandbox через QEMU-user.

| Файл | Действие |
|---|---|
| consumer runner-host | `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` (в reference workspace уже на server) |
| `tests/runner.nix` | цель `system="aarch64-linux"`; assert `buildHost`/`transport` **отсутствуют** в JSON |

**Verify:** smoke на aarch64-таргете (напр. RPi).

**Deps:** нет (V2 — deploy-rs/mkDeployNodes убраны, cross-arch целиком через binfmt). Реально — отложить до появления aarch64-цели.

---

## Сводка объёма

| Батч | новых файлов | правок | репо | можно end-to-end smoke? |
|---|---|---|---|---|
| A | 1 (`deploy.nix`) | 3 (`types`, `instances`, `default`, `tests`) | nixtache | нет (только tests) |
| B | 4 (`deploy-target/*`) | 2 (`flake`, `tests`) | nixtache | нет (только tests) |
| C | 2 (action, workflow) | 1 (`flake`) | nixtache | нет (нужен consumer) |
| D | 4 (consumer) | 3 | nixos-configuration | **да** (desktop/laptop) |
| E | ~3 + consumer prep | ~5 | оба | да (server) |
| F | 0–1 | 2 | оба | да (aarch64) |

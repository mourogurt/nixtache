# REVIEW-ISSUES — разбор консистентности direct-deploy

> Ревью поэтапной детализации (`01`–`07`) против текущего кода `nixtache` и
> реального поведения тулов (deploy-rs, NixOS options, nix CLI).
> Дата ревью: 2026-08-06. Дата решений: 2026-08-06 (все применены к spec-файлам).

## TL;DR

Дизайн в целом **архитектурно здоровый** (vendor-agnostic, path-based секреты,
mode-by-branch, ab-image для chicken-and-egg — всё опирает на проверенные NixOS-
механизмы). Найденные проблемы были **в технических деталях код-семплов**, не в
подходе. Самые тяжёлые — два BLOCKER'а в Stage 02/05 вокруг deploy-rs (его API
было понято неверно): Tier-1 magic-rollback через `--checks` нереализуем, nodeless
ad-hoc вызов не поддерживается.

**B1/B2 → superseded V2-пивотом** (см. ниже): активация переведена на systemd
(`nixtache-apply.service` + polkit), deploy-rs выкинут полностью, зоопарк
sudo/doas/run0 исчез вместе с ним. Все 10 исходных issues + V2-разворот закрыты и
применены к spec-файлам. Код Batch A + B под V2 реализован, `nix flake check`
зелёный.

## 🔄 V2-пивот: systemd-unit активация, без deploy-rs (supersedes B1/B2)

**Триггер:** после B1/B2/S1-… пользователь указал, что в workspace используется
`doas` (`security.doas.enable = true` глобально), и предложил вообще всё решать
через systemd (run0/polkit — «он везде есть»), вместо подбора escalation-тула.

**Тех. база (verified):** systemd 261.1 в nixpkgs → `run0` провожен
(`systemd-run0` SUID-обёртка + `pam.services.systemd-run0`); polkit на NixOS —
стандарт; действие `org.freedesktop.systemd1.manage-units` позволяет правилом
«deploy-юзер может `start` ровно одного юнита».

**Решение (Вариант 2):** активация всегда через root-юнит `nixtache-apply.service`
(polkit-triggered), копирование closure — `nix copy --to`, probe+rollback (B1) —
внутри юнита. deploy-rs выкинут целиком.

**Что это убивает:**
- ❌ Весь выбор doas/sudo/sudo-rs/run0 — нет escalation-тула, polkit+systemd
  универсальны.
- ❌ deploy-rs (flake input + `deploy` CLI в hostPackages).
- ❌ `nixtache.lib.mkDeployNodes` (B2) — нет `deploy.nodes`.
- ❌ `activate.custom` / Tier-1 в deploy-rs — probe живёт прямо в apply-юните.
- ❌ `transport` поле карты (один путь активации) и метод `"deploy-rs"` → `"live"`.

**Реализовано (Batch A+B V2, `nix flake check` зелёный):**
- `modules/runner/types.nix` — `deployTargetType` с `method = "live"|"ab-image"`
  (без `transport`, без `buildHost`).
- `modules/runner/deploy.nix` (новый) + `instances.nix` S1-рефактор (`_extraRunnerEnvs`).
- `modules/deploy-target/{options,user,apply,health-check,default}.nix` (новый
  модуль): `nixtache-apply.service` (set+switch+probe+rollback), polkit-правило
  на `systemctl start nixtache-apply.service`, `nixtache-deploy` group + pointer
  dir, deploy-user provisioning, Tier-0 `nixtache-health-check.service`.
- `tests/runner.nix` (+6 deploy-сценариев), `tests/deploy-target.nix` (новый,
  5 сценариев, 22 check).

---

## 🔴 BLOCKER — ✅ решено (B1/B2 superseded V2)

### B1. Флага `deploy-rs --checks` не существует — ✅ решено (вариант 1)

**Суть:** Tier-1 magic-rollback опирался на `deploy .#cfg --magic-rollback --checks
"$checks"`, где checks = `systemctl is-active <criticalUnit>`. deploy-rs такого
флага не имеет — `magicRollback` проверяет только SSH-достижимость (inotify-watcher
в `tempPath`), а не произвольные health-команды.

**Решение (вариант 1 — probe внутри activation):** `criticalUnits`-probe вшит в
**activation script на самой цели** через `activate.custom`. Скрипт прогоняет
`switch-to-configuration switch`, локально опрашивает `systemctl is-active --wait
<unit>` в окне `healthCheckTimeout`, при fail сам делает локальный
`nix-env --switch-generation` (rollback) + `exit 1` → deploy-rs `autoRollback`.

**Обоснование выбора:** если апдейт ломает `sshd`, SSH-based rollback бесполезен
(деплоер не достучится). Проверка обязана работать локально на цели уже после
мутации — скрипт крутится под sudo на цели, общается с systemd через dbus, SSH не
нужен.

**Правки:** `05-rollback.md` (Tier-1 переписан + probe-script), `02-action.md`
(`_deployRs` упрощён, ссылается на вшитый probe), `0001` §7.2 псевдокод + N5.

### B2. deploy-rs не умеет nodeless ad-hoc вызов — ✅ решено (`deploy.nodes` из карты)

**Суть:** «nodeless + CLI-override'ы из карты» невозможно — deploy-rs требует
`deploy.nodes.<name>` декларативно.

**Решение:** `deploy.nodes` **генерируется из карты** хелпером
`nixtache.lib.mkDeployNodes` (принимает `nixosConfigurations` consumer'а + JSON
карты + `criticalUnits`/`healthCheckTimeout` via `nix eval`, собирает `deploy.nodes`
с `activate.custom` + probe-script из B1). Карта остаётся единственным источником
правды; `deploy.nodes` — производный flake-output. Секреты в `deploy.nodes` не
нужны — ключ подставляется через `sshOpts -i $CREDENTIALS_DIRECTORY/deploy_ssh_<name>`
(LoadCredential path фиксирован).

**Правки:** `05-rollback.md` (раздел «Reconcile `deploy.nodes`» переписан),
`02-action.md` (контекст джобы + `_deployRs`), `0001` §7.2/N5.

---

## 🟠 SIGNIFICANT — ✅ решено

### S1. Механизма `_extraRunnerEnvs` не существует — ✅ решено (вариант 1: рефактор)

**Суть:** код-семпл `deploy.nix` использовал `_extraRunnerEnvs`, но в
`instances.nix` `runner.envs` строится inline — никакого агрегатора нет.

**Решение (вариант 1):** рефакторим `instances.nix` — выносим опцию
`services.nixtache.runner._extraRunnerEnvs` (`attrsOf str`, internal), вливаем в
`runner.envs` через `mkMerge` вместе с уже захардкоженными `NIXTACHE_*`/`HAS_SANDBOX_CAP`.
Тогда `deploy.nix` (и будущие подмодули) честно дописывают свой env-ключ без правки
`instances.nix`. Публичный контракт `runner.envs` не меняется.

**Правки:** `01-map-contract.md` (`deploy.nix` wiring + артефакты этапа).

### S2. `forgejoPort` — unbound переменная — ✅ решено (новая опция)

**Суть:** gating-unit script ссылался на `${forgejoPort}`, но в модуле есть только
строка `forgejoUrl`.

**Решение:** добавить опцию `services.nixtache.runner.forgejoPort` (numeric; дефолт
парсится из `forgejoUrl`). Скрипт использует `config.services.nixtache.runner.forgejoPort`.

**Правки:** `06-ab-image.md` (gating-unit script).

### S3. `systemd.paths.<name>.pathExists` — неверная NixOS API — ✅ решено

**Суть:** top-level `pathExists` не существует; правильно `pathConfig.PathExists`.

**Решение:** заменено на `systemd.paths.nixtache-ab-apply.pathConfig.PathExists = "..."`.

**Правки:** `06-ab-image.md` (gating-unit).

### S4. `nix build` не принимает `--build-host` — ✅ решено (убрать, приоритет nix build)

**Суть:** Stage 07 заявлял `--build-host` для `_abImage` (через `nix build`), но
это флаг `nixos-rebuild`, не `nix build`.

**Решение:** поле `buildHost` и `--build-host` убраны везде. Cross-arch сборка —
через `boot.binfmt.emulatedSystems` на runner-host (приоритетный путь, единый для
всех дериваций). Native-сборка на цели — через deploy-rs
`deploy.nodes.<name>.remoteBuild = true` (per-node флаг, **не** поле в карте).

**Правки:** `01-map-contract.md` (тип убран + JSON), `07-cross-arch.md` (переписан),
`0001` §5 таблица + §7.3 + §11.9, `README.md` (строка этапа 9).

### S5. Stage 03 «combined pipeline» дублировал `nix-check` — ✅ решено (вариант b)

**Суть:** скелет `build`-джобы показывал inline-шаги (`flake-validation`, …),
дублируя reusable `nix-check.yml`.

**Решение:** зафиксирован вариант **(b)**, `build` обязан вызывать nix-check через
`uses: nixops/nixtache/.forgejo/workflows/nix-check.yml@main` (без inline-шагов),
`deploy.needs: build`. Принцип «nixtache — единственный источник CI-логики» сохранён.

**Правки:** `03-workflow.md` (раздел «Два варианта» + скелет).

---

## 🟡 MINOR — ✅ решено

### M1. Мусор в тексте (CJK) — ✅ исправлено

`03-workflow.md:32` `耦合ён` → `жёстко сцеплен`. Попутно найден и исправлен второй
пробел: `0001-direct-deploy.md:31` `整个` → `весь`.

### M2. `image.repart` — не дефолтный модуль — ✅ решено (явный imports)

**Суть:** `image.repart.*` — real NixOS-опция (модуль
`nixos/modules/image/repart.nix`, verified в nixpkgs master), но не входит в
дефолтный import-list.

**Решение:** в `06-ab-image.md` consumer-prep добавлен шаг 0 — явный
`imports = [ "${nixpkgs}/nixos/modules/image/repart.nix" ];` с объяснением.

### M3. `HAS_SANDBOX_CAP` в `deploy-target` action — ✅ решено

**Суть:** существующие `rebuild-configurations`/`rebuild-devshells` при
`HAS_SANDBOX_CAP=0` добавляют `--no-sandbox`; новый `deploy-target` не упоминал
этот паттерн.

**Решение:** `deploy-target` action читает `HAS_SANDBOX_CAP`, при `0`/unset
добавляет `--no-sandbox` к `nix build`/`nixos-rebuild` (как `rebuild-*`).
Зафиксировано в `02-action.md` (`_deployRs` + контекст джобы).

---

## Что проверено и подтверждено корректным

| Элемент | Статус |
|---|---|
| Vendor-agnostic + path-based секреты (LoadCredential) | ✅ Едино во всех 7 файлах, совпадает с контрактом модуля |
| `modules/runner/{cache,ssh,instances,types,…}.nix` существуют как заявлено | ✅ `deploy.nix` честно мержится по работающему паттерну |
| `nix-check.yml` — reusable `on: workflow_call` | ✅ Оба варианта проводки (a/b) технически достижимы |
| `boot.loader.systemd-boot.bootCounting.enable` | ✅ существует (verified MCP) |
| `systemd.sysupdate.{enable,transfers,reboot}` | ✅ существует (verified MCP) |
| `boot.uki.tries` | ✅ существует (verified MCP) |
| `boot.binfmt.emulatedSystems` (closed enum, `aarch64-linux` в списке) | ✅ существует (verified MCP) |
| `image.repart.{name,version,split,partitions}` | ✅ существует (verified напрямую в nixpkgs master, MCP-индекс не покрывает) |
| Модель доставки / mode-by-branch согласована с `autoUpgrade` | ✅ (тянет только `main` → на PR нигде не мутирует) |
| Chicken-and-egg через ab-image + idle-gate | ✅ архитектурно здраво, референс nixcademy корректен |
| deploy-rs `magicRollback`/`autoRollback`/`activate.custom`/`remoteBuild`/`sshOpts` | ✅ существуют (verified по README `serokell/deploy-rs`) |

---

## Итоговый порядок имплементации (обновлён с решениями)

1. **Рефактор `instances.nix`** (S1) — вынести `_extraRunnerEnvs`, влить в
   `runner.envs`. Фундамент для всего Stage 01 wiring.
2. **Stage 01** (`deploy.nix` + `deployTargetType`) — карта → env + LoadCredential.
   +тесты. Поле `buildHost` не добавляем (S4).
3. **Хелпер `nixtache.lib.mkDeployNodes`** (B2) — генерация `deploy.nodes` из
   карты + `criticalUnits`, с `activate.custom` probe-script (B1). Без него Stage
   02/05 некодабельны.
4. **Stage 02** (`deploy-target` action) — discovery → probe → activate;
   `HAS_SANDBOX_CAP`-aware (M3); без `--checks`/`--build-host`.
5. **Stage 03** (workflow, вариант b) — `build.uses: nix-check.yml` + `deploy`.
6. **Stage 04** (consumer wiring) — карта + приёмный модуль + `image.repart`
   imports (M2).
7. **Stage 05** (Tier-0 приёмный модуль + Tier-1 probe-script из B1).
8. **Stage 06** (ab-image) — с `forgejoPort` (S2) + `pathConfig.PathExists` (S3).
9. **Stage 07** (cross-arch) — binfmt + опц. `remoteBuild` (S4).

## Методология ревью

- Прочитаны: `0001-direct-deploy.md` + все 7 файлов `direct-deploy/` + README.
- Сверка с кодом: `modules/runner/{instances,cache,ssh,types}.nix`, `flake.nix`,
  `.forgejo/workflows/nix-check.yml`, структура `.forgejo/actions/`.
- NixOS-опции проверены через MCP (nixos.org index) + прямой fetch
  `nixos/modules/image/repart.nix` из nixpkgs master.
- deploy-rs API — по официальному README `github.com/serokell/deploy-rs`
  (`magicRollback`, `autoRollback`, `activate.custom`, `remoteBuild`, generic
  options + CLI-override behaviour).
- nixcademy-пост (база для Stage 06) — сверен с актуальным содержимым.

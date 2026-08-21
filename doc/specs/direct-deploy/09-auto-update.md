# 09 — Auto-update (unified: flake ↔ ab-image)

> Замена «штатного обновления из репы» (`system.autoUpgrade`) единым модулем,
> который по типу системы сам выбирает механизм: **flake-path** (non-OTA) или
> **ab-image-path** (OTA/sysupdate). Модуль ставится на **таргет** и НЕ требует
> runner-стека — ни контейнера, ни Forgejo, ни карты `deploy.targets`.
>
> **Статус:** 📝 черновик (spec; модуль `modules/auto-update/default.nix` ещё не
> существует — conformance-контракт фиксируется в `TEST-SPECS-AUTO-UPDATE.md`).

## 1. Проблема

`system.autoUpgrade` (таймер → `nixos-rebuild switch --flake <repo>`) конфликтует
с моделью nixtache по трём осям:

1. **Rollback.** `nixos-rebuild switch` активирует без probe — нет Tier-1
   (probe `criticalUnits` + auto-revert из `nixtache-apply.service`, 05-rollback).
   Сломанный конфиг остаётся активным до ручного вмешательства.
2. **OTA.** На A/B-таргете (`method = "ab-image"`) `nixos-rebuild` в принципе не
   применим: appliance-профиль (`nix.enable = false`, `/nix/store` — ro squashFS).
   Обновление там — pull staged-образа через `systemd-sysupdate` в неактивный слот.
3. **Конфликт с CI-deploy.** Два независимых канала активации (таймер autoUpgrade
   и CI `deploy.yml` через pointer+apply-unit) ничего не знают друг о друге.

Нужен **один** модуль: consumer задаёт унифицированные опции, модуль настраивает
правильный механизм per system type. Требования к дизайну: максимально
унифицированно; per-path опции — по минимуму; гибкость сохранить.

## 2. Где живёт модуль

**Новый standalone-модуль** `modules/auto-update/default.nix`, экспорт
`nixosModules.auto-update`, дерево `services.nixtache.auto-update.*`.

Почему не внутри `deploy-target`:

- Разные ответственности: `deploy-target` — *push*-приёмник (политика «кто может
  прислать и как активировать»), `auto-update` — *pull*-источник (политика «когда
  и откуда самому подтянуть»). Таргет может хотеть pull без CI-приёма вовсе.
- deploy-target импортируется **каждым** таргетом (default `enable = true`) —
  тащить в него опции, которые 90% потребителей не трогают, раздувает его
  контракт.
- ab-image-таргеты с co-imported `ab-image` + appliance-профилем могут вообще не
  иметь live-приёма (deployUser не задан) — auto-update там единственный канал.

Почему не внутри `ab-image` / `runner`: auto-update — runtime-политика таргета,
не build-time образа и не инфраструктура раннера.

Композиция (обе стороны осознанно зависят от существующих модулей):

| Путь | Требует | Почему |
|---|---|---|
| `flake` | `nixosModules.deploy-target` (apply-unit + probe) | активация идёт через `nixtache-apply.service`, не через raw `nixos-rebuild` (§5) |
| `ab-image` | `systemd.sysupdate.enable` (через `ab-image` или `ab-provision`) | auto-update только триггерит pull; transfers/slots — не его зона (§11.7 TEST-SPECS) |

Модуль **не** импортирует deploy-target сам и **не** требует его опций на верхнем
уровне: все обращения к `config.services.nixtache.deploy-target.*` — через
`builtins.hasAttr`/`or`-guard'ы (паттерн из `ab-provision.nix`), assert'ы мягко
объясняют, что импортировать.

## 3. Выбор пути: `method = "auto"` (default) с явным override

```nix
effectiveMethod =
  if cfg.method != "auto" then cfg.method
  else if abPresent then "ab-image" else "flake";
# abPresent = deploy-target.ab.enable (если модуль импортирован)
#          || ab-image.enable           (если модуль импортирован)
```

**Взвешивание альтернатив:**

| Подход | Плюсы | Минусы | Вердикт |
|---|---|---|---|
| Только explicit `method = "flake" \| "ab-image"` (обязательная опция) | Нулевая магия | Consumer дублирует факт, уже выраженный в `ab.enable`/`ab-image.enable`; рассинхрон ловится только assert'ом | отклонён как **default** |
| Только derive (без override) | Единственный источник правды | Нет escape hatch: таргет с co-imported `ab-image`, который consumer хочет обновлять flake-путём (edge: transition-период A/B-миграции), невыразим | отклонён |
| **`"auto"` default + explicit override** | В типовом случае consumer вообще не задаёт `method`; edge покрыт override + assert'ами на противоречия | Derivation-логика должна быть задокументирована и покрыта тестами | **выбран** |

Invariant: `method = "ab-image"` (явный или derived) всегда проверяется теми же
assert'ами, что explicit, — auto не ослабляет валидацию.

## 4. Дерево опций `services.nixtache.auto-update.*`

Каждая опция: имя — тип — default — семантика. Все `mkOption` обязаны иметь
`description` (правило репо, enforced docs-CI).

```nix
services.nixtache.auto-update = {
  enable = false;
  # bool, default false. Включает auto-update канал на этом таргете.
  # Assert: несовместим с system.autoUpgrade.enable = true (§7, A1).

  method = "auto";
  # enum [ "auto" "flake" "ab-image" ], default "auto".
  # "auto": derive — ab-image.enable || deploy-target.ab.enable → "ab-image",
  #         иначе "flake". Явное значение отключает derive (assert'ы те же).

  dates = "daily";
  # str (systemd OnCalendar), default "daily". Расписание poll-таймера
  # nixtache-auto-update.timer. Общая для обоих путей.

  randomizedDelaySec = "1h";
  # str (systemd time span), default "1h". RandomizedDelaySec таймера —
  # разносит pull по флоту, не долбит deployer/git одновременно.

  persistent = true;
  # bool, default true. Persistent= на таймере: пропущенный прогон (машина
  # была выключена) добирается при следующей загрузке. Важно для laptop/desktop.

  flake = {
    url = null;
    # nullOr str, default null. Flake reference: "git+ssh://host/org/repo.git",
    # "github:org/repo", локальный path "/etc/nixos". Обязателен при
    # effectiveMethod = "flake" (assert A3).

    ref = null;
    # nullOr str, default null. Ветка/ref. Когда задан — дописывается к url:
    # для git-URL как `?ref=<ref>`, иначе (github:/path) как `/<ref>`.
    # null = ref уже зашит в url (или default-ветка).

    configuration = null;
    # nullOr str, default null → config.networking.hostName. Имя атрибута в
    # nixosConfigurations: build target = `<url>#nixosConfigurations.<conf>`.
    # Совпадает с конвенцией карты deploy (01-map-contract).

    flags = [ "--refresh" "-L" ];
    # listOf str, default [ "--refresh" "-L" ]. Флаги `nix build`
    # (эквивалент system.autoUpgrade.flags).

    sshPrivateKeyFile = null;
    # nullOr path, default null. Path-based секрет (sops/agenix/systemd) с
    # SSH-ключом для fetch ПРИВАТНОГО flake/inputs. Подкладывается в сервис
    # через LoadCredential → GIT_SSH_COMMAND. null = fetch без ключа
    # (публичный flake / уже настроенный ssh). Заменяет ручной override
    # systemd.services.nixos-upgrade.environment.GIT_SSH_COMMAND, который
    # consumer сегодня делает под autoUpgrade.
  };

  rebootPolicy = "never";
  # enum [ "never" "if-needed" "window" ], default "never".
  #   "never"     — только switch/запись слота; reboot — дело оператора.
  #   "if-needed" — flake: reboot, если загруженное ядро != ядро нового
  #                 toplevel (сравнение /run/booted-system vs /run/current-system
  #                 после apply); ab-image: reboot сразу после записи слота
  #                 (image-апдейт всегда требует reboot).
  #   "window"    — как "if-needed", но reboot откладывается: marker-файл
  #                 /var/lib/nixtache/reboot-pending + отдельный
  #                 nixtache-auto-update-reboot.timer (OnCalendar = rebootWindow.start),
  #                 который ребутит только если marker есть и текущее время
  #                 внутри окна. За окном — ждёт следующего прогона таймера.
  # Assert: "ab-image" + gating-host требует "never" (A6, §6.2).

  rebootWindow = { start = "02:00"; end = "05:00"; };
  # submodule { start: str; end: str; }, HH:MM. Имеет смысл только при
  # rebootPolicy = "window" (assert A5: start != end).

  ab = {
    poll = <derived>;
    # bool, defaultText: "!services.nixtache.deploy-target.ab.gating"
    # (true на remote-таргете, false на gating/runner-host).
    # true: таймер триггерит pull (systemd-sysupdate.service).
    # false: таймер НЕ трогает sysupdate — канал чисто CI-driven
    # (на gating-хосте CI сам сигналит ab-pending; auto-update timer там
    # провижинится, но service — no-op с журнальным маркером "ci-driven").
  };
};
```

**Чего в дереве НЕТ и почему (отклонённые опции):**

- `ab.source` — **нет**. Source/transfer'ы принадлежат `ab-provision`
  (`partitions.source`) / `ab-image` (`stagingPath`) — единственный владелец
  (TEST-SPECS §11.7). Auto-update не дублирует: он только **валидирует**, что
  source разрешим (assert A4), и триггерит. Канал/пиннинг версий = выбор
  другого staging-subdir в `partitions.source` (consumer-side), не опция
  auto-update (§9, non-goals).
- `healthProbe*`/`criticalUnits` — **нет**. Flake-путь переиспользует
  `deploy-target.criticalUnits`/`healthCheckTimeout` напрямую через apply-unit —
  второй источник = рассинхрон (B2-принцип из 05-rollback).
- `ab.reboot*` — **нет**. Reboot-политика единая (`rebootPolicy`), различие
  путей — внутри реализации (§6.2).

## 5. Flake-путь (non-OTA): активация ЧЕРЕЗ `nixtache-apply.service`

**Решение: через apply-unit, не raw `nixos-rebuild switch`.** Обоснование:

- Tier-1 (probe `criticalUnits` → auto-revert профиля → exit 1) — существующая,
  оттестированная история отката (05-rollback). Raw `nixos-rebuild` её обходит:
  сломанный switch остаётся активным.
- Один код-путь активации для CI и для таймера: одинаковый probe, одинаковые
  журнальные маркеры, одинаковая политика «кто root» (deploy-user-логика CI не
  нужна таймеру — таймер и так root, но *юнит* общий).
- `nixos-rebuild` на таргете тянет perl-обвязку и делает `switch` напрямую —
  ровно то, от чего V2 ушёл.

Механика `nixtache-auto-update.service` (Type=oneshot, root) при `flake`:

```
1. new=$(nix build --no-link --print-out-paths "<url>#nixosConfigurations.<conf>.config.system.build.toplevel" <flags>)
2. cur=$(readlink -f /run/current-system)
3. [ "$new" = "$cur" ] && { echo "nixtache-auto-update: already at $new"; exit 0; }   # idempotent no-op
4. [ -f /var/lib/nixtache/pending-system ] && { echo "...: CI deploy pending — skipping"; exit 0; }  # precedence §8
5. echo "$new" > pending-system.tmp && mv pending-system.tmp /var/lib/nixtache/pending-system   # atomic
6. systemctl start nixtache-apply.service        # probe+rollback внутри (05 §Tier-1)
7. rebootPolicy: never → готово; if-needed → сравнить kernel → reboot; window → touch reboot-pending
```

Требование: `deploy-target.enable = true` (assert A2) — apply-unit и pointer-dir
приходят оттуда; `deployUser` при этом может быть `null` (таймер root, SSH-фасад
не нужен). Конкурентность с CI: `nixtache-apply.service` — oneshot; повторный
`start` во время работы — no-op (systemd сериализует), pointer пишется атомарно
(tmp+rename).

## 6. AB-image-путь (OTA): poll-триггер поверх sysupdate

### 6.1. Remote-таргет (`ab.poll = true`)

```
nixtache-auto-update.timer → service:
1. sysupdate НЕ reboot'ит сам (Reboot= в transfers остаётся выключенным —
   auto-update владеет reboot-политикой, см. A7-warning)
2. systemctl start systemd-sysupdate.service      # pull https://.../ab-stage/<cfg>/ → слот B
3. детект «установил ли новую версию»: journal -u systemd-sysupdate --since <t0>
   grep "Successfully installed"
4. rebootPolicy: never → готово; if-needed → systemctl reboot;
   window → touch reboot-pending → nixtache-auto-update-reboot.timer снимет в окне
```

### 6.2. Gating/runner-host (`ab.poll = false`, derived из `ab.gating`)

На runner-host активацию и reboot владеет gating-unit (`nixtache-ab-apply`,
idle-wait по Forgejo API, 06 §gating). Auto-update здесь — **no-op by design**:
канал local-self чисто CI-driven (CI stage'ит образ и `touch ab-pending`).
Сервис провижинится, но выходит с маркером `ci-driven channel — nothing to do`,
поэтому `dates`/`randomizedDelaySec` там безвредны. Assert A6:
`gating && rebootPolicy != "never"` → eval-fail (reboot'ит gating, двойная
политика недопустима).

> Отклонённая альтернатива: «auto-update на gating-хосте делает touch ab-pending
> по таймеру» — дублирует сигнал CI, добавляет второй триггер без новой
> информации (staging — источник правды по версиям, а не флаг).

## 7. Asserts / validation matrix

| ID | Условие | Сообщение (суть) |
|---|---|---|
| A1 | `cfg.enable && config.system.autoUpgrade.enable` | «auto-update replaces system.autoUpgrade — отключите последний (миграция §10)» |
| A2 | `enable && effectiveMethod == "flake" && !(deploy-target.enable or false)` | «flake-путь активирует через nixtache-apply.service — импортируйте nixosModules.deploy-target (deployUser можно не задавать)» |
| A3 | `enable && effectiveMethod == "flake" && flake.url == null` | «flake.url обязателен при method flake/auto→flake» |
| A4 | `enable && effectiveMethod == "ab-image" && !(sysupdate.enable or false)` + source не разрешим | «ab-image-путь требует systemd.sysupdate (ab-image или ab-provision с partitions.source)» — модуль чекает `config.systemd.sysupdate.enable or false` и наличие `partitions.source`/`ab-image.enable` (hasAttr-guard) |
| A5 | `rebootPolicy == "window" && rebootWindow.start == rebootWindow.end` | «пустое окно reboot» |
| A6 | `effectiveMethod == "ab-image" && (deploy-target.ab.gating or false) && rebootPolicy != "never"` | «на gating-хосте reboot владеет nixtache-ab-apply (idle-gate); rebootPolicy должен быть never» |
| A7 (warning) | `effectiveMethod == "ab-image"` и любой transfer содержит `Transfer.Reboot == "yes"` | `lib.warn`: «auto-update владеет reboot-политикой; уберите Reboot=yes из transfers» |
| A8 | `method == "ab-image"` (explicit) && `!abPresent` | «method=ab-image задан явно, но ни ab-image.enable, ни deploy-target.ab.enable не включены — опечатка?» (fail) |

`abPresent` / все обращения к соседним модулям — через
`builtins.hasAttr "ab-image" config.services.nixtache` / `or false` guard'ы
(паттерн `ab-provision.nix`), чтобы модуль eval'ился standalone.

## 8. Приоритет каналов: CI vs auto-update

Оба канала **не дерутся** — правила:

1. **Общий механизм активации.** Flake-путь: CI и таймер пишут один pointer и
   стартуют один oneshot — активации сериализованы systemd, probe/rollback
   общий. AB-путь: версии выбирает sysupdate из staging (старшая по
   MatchPattern) — источник правды один, триггеров два (CI signal / timer pull).
2. **CI выигрывает гонку в моменте.** Если при прогоне таймера pointer
   `pending-system` уже существует (CI deploy в полёте) — auto-update
   **skip** с журнальным маркером (не перезаписывает чужую активацию).
3. **Идемпотентный no-op.** Если собранный toplevel == `/run/current-system`
   (CI уже задеплоил этот же ревизион) — таймер выходит без записи pointer.
   Зеркально: CI, задеплоивший свежий main, делает следующий прогон таймера
   no-op'ом.
4. **Рекомендуемая роль (документируется consumer'у):** CI = primary
   (низкая латентность, на зелёном nix-check), auto-update = **fallback-канал**
   (редкий `dates`, напр. weekly/daily с большим randomizedDelaySec) —
   подстраховка, если CI молчит. Оба включать можно и нужно; конфликта нет
   по пунктам 1–3.

## 9. Non-goals

- **Версионные каналы/пиннинг** (`stable` vs `nightly`, pin версии): решается
  выбором staging-subdir в `partitions.source` / отдельной веткой flake —
  consumer-scope, без специальных опций auto-update.
- **Build на runner с доставкой на таргет** (push-модель) — это и есть CI deploy;
  auto-update строит на таргете (как autoUpgrade). Remote-build offload не
  входит.
- **HTTP-probes** (N2 из 05) — отдельная фича rollback-стека.
- **Управление transfers/Source/Reboot=** — зона ab-provision/ab-image (§4).
- **Windowed reboot на gating/runner-host** — reboot там владеет idle-gate;
  окно поверх не имеет смысла (A6).
- **Pull-based OTA без sysupdate** (RAUC/mender/swupdate) — вне модели nixtache.

## 10. Миграция с `system.autoUpgrade`

### 10.1. Общий рецепт (любой consumer)

```nix
# БЫЛО:
system.autoUpgrade = {
  enable = true;
  flake = "git+ssh://forgejo@git.example.com/org/config.git#${config.networking.hostName}";
  allowReboot = false;
  flags = [ "--refresh" "-L" ];
};

# СТАЛО:
system.autoUpgrade.enable = false;                    # assert A1 иначе fail
imports = [ inputs.nixtache.nixosModules.deploy-target
            inputs.nixtache.nixosModules.auto-update ];
services.nixtache.auto-update = {
  enable = true;
  flake.url = "git+ssh://forgejo@git.example.com/org/config.git";
  # configuration = null → hostName (та же семантика, что `#${hostName}`)
  rebootPolicy = "never";                              # allowReboot=false
};
```

- `allowReboot = true` → `rebootPolicy = "if-needed"` (точнее оригинала:
  ребут только при смене ядра; autoUpgrade `allowReboot` ребутит на *любое*
  изменение `systemd.units`/`boot.kernelPackages` — честнее `if-needed`).
- Ручной override `systemd.services.nixos-upgrade.environment.GIT_SSH_COMMAND`
  (fetch приватного репо) → `flake.sshPrivateKeyFile = config.sops.secrets.<key>.path`.
- `system.autoUpgrade.dates` / `randomizedDelaySec` / `persistent` → одноимённые
  опции (совместимые значения OnCalendar/time span).
- Выигрыш миграции: probe+rollback Tier-1 из apply-unit вместо слепого switch.

### 10.2. Reference workspace (nixos-configuration — пример, не роль)

Текущее состояние (на момент спеки):

- `common/nixos.nix`: `system.autoUpgrade.enable = true`,
  `flake = "git+ssh://.../nixos-configuration.git#${hostName}"`,
  `allowReboot = mkDefault false`, `flags = [ "--refresh" "-L" ]`, плюс
  `systemd.services.nixos-upgrade.environment.GIT_SSH_COMMAND` с host key
  (fetch приватного репо + приватных inputs).
- `server/nixos.nix`: `autoUpgrade.allowReboot = true`.
- `common/deploy-target.nix`: уже импортирует `nixosModules.deploy-target`
  (apply-unit + criticalUnits на месте).

Миграция:

- **desktop/laptop (non-OTA, method derive → flake):** в `common/nixos.nix`
  удалить блок `autoUpgrade` + override `nixos-upgrade`, добавить
  `services.nixtache.auto-update = { enable = true; flake.url =
  "git+ssh://.../nixos-configuration.git"; flake.sshPrivateKeyFile = <host key /
  sops>; };`. `common/deploy-target.nix` уже даёт apply-unit → A2 удовлетворён.
- **server (OTA после перехода на ab-image):** после включения
  `deploy-target.ab.enable`/`ab-image.enable` derive сам переключится на
  `ab-image`; `flake.*`-опции игнорируются (документировано). До перехода server
  работает flake-путём, как desktop/laptop. `rebootPolicy = "never"` на gating-хосте
  (A6) — reboot по idle-gate.
- Во время A/B-transition server может временно иметь `ab-image.enable = true`
  (собирает образ), но ещё обновляться flake-путём → явный `method = "flake"`
  (escape hatch §3).

## 11. Observability

| Артефакт | Что даёт |
|---|---|
| `nixtache-auto-update.timer` | расписание (dates/randomizedDelaySec/persistent), `systemctl list-timers` |
| `nixtache-auto-update.service` | журнальные маркеры `nixtache-auto-update: <built\|already at\|CI pending — skipping\|ci-driven\|triggered sysupdate\|reboot pending>`; exit-код в `systemctl status` |
| `nixtache-apply.service` (flake-путь) | общий журнал активации + probe + rollback (05) |
| `nixtache-auto-update-reboot.timer` (только `window`) | `OnCalendar = rebootWindow.start`, потребляет marker `/var/lib/nixtache/reboot-pending` |
| State: `/var/lib/nixtache/{pending-system,reboot-pending}` | общие с CI-deploy marker'и (pointer) + отложенный reboot |
| `journalctl -u systemd-sysupdate` (ab-путь) | `Successfully installed version <v>` — детект auto-update'ом |

## 12. Артефакты этапа

- `modules/auto-update/default.nix` — НОВОЕ (опции §4, service/timer §5–6,
  asserts §7).
- `flake.nix` — `nixosModules.auto-update`, проводка в `checks` тестов
  `TEST-SPECS-AUTO-UPDATE.md`.
- `README.md` / `AGENTS.md` — строка про новый модуль (при реализации).

## 13. Связь с другими спеками

- `01` — `configuration` повторяет конвенцию имени карты (`<name>` ==
  `nixosConfigurations.<name>`).
- `05` — flake-путь переиспользует Tier-1 целиком (probe+rollback).
- `06`/`08` — ab-путь не трогает transfers/slots/source (single-owner §11.7
  TEST-SPECS), только триггерит и валидирует.

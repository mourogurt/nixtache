# Спека 0003 — Умный garbage collection в nixtache

> **Status:** draft — not implemented, awaiting decision.
> Moved from `doc/specs/` to `doc/drafts/`: unimplemented drafts do not
> live next to the implemented spec corpus.

> **Статус:** черновик (на ревью) — **до реализации жду подтверждения**
> (см. «Контрольная точка» в §10)
> **Дата:** 2026-08-06
> **Зона:** `nixtache` (`modules/runner/default.nix` + новый `modules/runner/gc.nix`
> + правка `modules/runner/instances.nix` для env-экспорта) + reusable composite
> actions (`rebuild-configurations`, `rebuild-devshells`).
> **Ссылки:** `modules/runner/default.nix:166-176` (текущий тупой GC);
> `modules/runner/store.nix` (relocated store `/srv/nix`, `nix-daemon-custom`);
> `modules/runner/cache.nix` (`nix-serve-ng` поверх того же стора);
> спека 0002 (транзитивный кэш — взаимодействие в §7).

---

## 1. Цель

Сегодня GC раннера — тупой и разрушительный
(`modules/runner/default.nix:168-172`):

```nix
gc = {
  automatic = true;
  dates = "*-*-01 04:00";                # раз в месяц
  options = "--delete-older-than 30d";   # вычистить всё старше 30 дней
};
```

`--delete-older-than 30d` удаляет все profile-generation старше 30 дней, а
затем `nix-collect-garbage` собирает **всё**, не достижимое из оставшихся
root'ов. CI билдит `nixosConfigurations.*` через `nix build --no-link` и
`devShells.*` через `nix print-dev-env` — **ни один output не пинится как
GC-root**, поэтому раз в месяц стор вычищается подчистую, и следующая CI-сборка
пересобирает весь closure (gcc, Qt6, nixpkgs-toolchain) с нуля или тянет его из
внешних substituter'ов. Дополнительно: `nix-serve-ng` отдаёт narinfo **из того
же стора**, в котором собирает раннер → месячный GC вычищает и пути, которые
desktop/laptop сервер-стороне-substitut'ят с `bincache.<domain>`.

**Цель этой спеки** — заменить тупой time-based GC на **умный**: сохранить в
сторе именно то, что нужно CI (замыкания `nixosConfigurations.*` и
`devShells.*`), а всё transient-ное (промежуточные сборки, старые `.drv`,
scratch) — собирать только когда диск реально заполняется. Конкретно:

1. GC срабатывает **по порогу заполнения диска**, а не по календарю → стор не
   вычищается, пока есть место;
2. то, что CI только что собрал (конфиги + девшеллы), **пинится как GC-root** →
   гарантированно переживает любой GC (даже при полной уборке);
3. пиннинг обновляется **при каждом билде** (перезаписью), поэтому устаревшие
   замыкания сами становятся transient и уходят в следующую уборку;
4. сохраняется **vendor-agnostic** природа модуля: модуль не знает имён
   consumer-ских конфигов/девшеллов — пиннингом владеют composite-actions
   (которые и так уже открывают имена через `nix flake show`).

### Не-цели (out of scope)

- **Per-build retention по N последних сборок** (rollback/bisect) — v1 хранит
  ровно один root на атрибут (последний собранный). Хранение истории — через
  `angrr`/профили, отдельная спека (§8.2).
- **Мониторинг заполнения стора** (алёрты на диск) — обозначить как future,
  вне scope.
- **Смена `nix-serve-ng`** на Attic/Harmonia — принадлежит спеке 0002.

---

## 2. Требования и ограничения

| # | Требование | Как обеспечено |
|---|---|---|
| R1 | **Сохранить CI-кэш** — замыкания конфигов и девшеллов переживают GC | GC-root пиннинг в `gcroots/nixtache/` (§5, §6) |
| R2 | **Не разрастаться бесконечно** — transient вычищается | size-threshold GC: `nix-store --gc --max-freed` при заполнении (§4) |
| R3 | **Vendor-agnostic** — модуль не хардкодит `.#nixosConfigurations.server` | Модуль даёт только директорию + env; пиннинг — в composite-actions (§6) |
| R4 | **Опциональность** — можно вернуть старое поведение | `gc.strategy = "time"` (legacy) или `"off"` (§5.1) |
| R5 | **Не хранить секреты** | GC не требует новых секретов; всё на публичных путях стора |
| R6 | **Корректность для relocated store** | GC-сервисы и gcroots — внутри контейнера, в `/nix/var/nix/...` (= `/srv/nix/var/nix/...` на хосте) (§9) |
| R7 | **Детерминированность** — `keep-outputs` всегда выкл | `nix.settings.keep-outputs = mkForce false` (§4.3) |
| R8 | **Реактивная защита от OOM-на-диске во время билда** | `nix.settings.min-free`/`max-free` (§4.2) |
| R9 | **Тестовое покрытие** (правило репо: «каждая опция — с тестом») | `tests/runner.nix` + сценарии GC (§11) |
| R10 | **Деградация безопасна** — если actions не пиннят, ничего не ломается | actions толерантны к отсутствию `NIXTACHE_GC_ROOTS_DIR` (fallback на `--no-link`, legacy) (§6) |

---

## 3. Контекст (что уже есть)

- **`default.nix:166-176`** — единственный владелец `nix.gc`/`nix.optimise`/`nix.settings`
  внутри контейнера. Этот блок переедет в новый `gc.nix` (default.nix только
  импортирует), вместе с reactive `min-free`/`max-free`.
- **`store.nix`** при `store.path != "/"` relocate'ит стор в `<path>/nix`
  (дефолт consumer'а — `/srv`) и крутит `nix-daemon-custom` + `nix-daemon-storage`
  с `BindPaths=/srv/nix:/nix`. Значит **GC должен работать внутри контейнера**
  (против `nix-daemon-custom`), а gcroots должны лежать в
  `$NIX_STATE_DIR/gcroots/` relocated-стора (=`/nix/var/nix/gcroots/` внутри
  контейнера = `/srv/nix/var/nix/gcroots/` на хосте) — только так коллектор их
  просканирует (§9).
- **`cache.nix`** крутит `nix-serve-ng` поверх того же стора →_paths, удалённые
  GC, перестают отдаваться и как кэш для desktop/laptop. R1 выгоден вдвойне.
- **`instances.nix:111-117`** — единственное место, где собирается
  `runner.envs` (act_runner, mode-agnostic) из option-derived значений:
  `NIXTACHE_{FLAKE,UPDATE}_GIT_USER`, `NIXTACHE_BOT_{NAME,EMAIL}`,
  `HAS_SANDBOX_CAP`. Сюда же добавится `NIXTACHE_GC_ROOTS_DIR` (§6.3).
- **Composite-actions** (`rebuild-configurations`, `rebuild-devshells`) уже
  открывают имена через `nix flake show --json` → добавление `--out-link`
  тривиально и не требует знать consumer'а.

### Как делают другие (ресерч)

- **nix-community build-hosts** (`modules/nixos/common/builder.nix` +
  `modules/shared/free-space.bash`): выключают `nix.gc.automatic`, крутят
  hourly-сервис `free-space`, который в цикле делает
  `nix-store --gc --max-freed 100G`, пока заполнение корня не станет < 85 %.
  Reactive `min-free=1G`/`max-free=50G` — из базового `nix-daemon.nix`. Это
  образец, который берётся за основу Layer A.
- **nix-community Hydra host** (`modules/nixos/hydra.nix`):
  `nix.settings.keep-outputs = lib.mkForce false` — детерминированно выключено,
  иначе GC неэффективен.
- **Hercules-CI agent**: вообще не настраивает GC, полагается на бинарный кэш +
  re-substitution. Подтверждает, что для долгоживущих раннеров важно именно
  size-based GC + кэш, а не time-based.
- **`nix build --out-link <gcroots>/<name>`** — документированный способ
  создать permanent GC-root; `nix-collect-garbage --delete-older-than` такие
  пути **никогда** не собирает (флаг чистит только profile-generations, а
  достижимость из root'ов — чисто графовая, без учёта возраста).
- **Девшеллы**: `.#devShells.<system>.<name>.inputDerivation` — стандартная
  цель для пиннинга (замыкание = все `buildInputs` шелла; паттерн из
  nix-direnv/cachix-action).

---

## 4. Архитектура — три слоя

```
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER A (модуль, gc.nix): УМНЫЙ GC-ДВИЖОК                            │
│  ─ замена тупого monthly --delete-older-than                          │
│  ─ size-threshold: free-space сервис собирает transient при >порога   │
│  ─ reactive: min-free/max-free защищают билд от OOM-на-диске          │
│  ─ keep-outputs = mkForce false (детерминированно)                    │
├──────────────────────────────────────────────────────────────────────┤
│  LAYER B (модуль, gc.nix + instances.nix): КОНТРАКТ GC-ROOTS          │
│  ─ tmpfiles: /nix/var/nix/gcroots/nixtache/                          │
│  ─ env NIXTACHE_GC_ROOTS_DIR → каждый job (через runner.envs)        │
├──────────────────────────────────────────────────────────────────────┤
│  LAYER C (composite-actions): ПИННИНГ                                 │
│  ─ rebuild-configurations: nix build --out-link $ROOTS/cfg-<name>    │
│  ─ rebuild-devshells:     nix build --out-link $ROOTS/shell-<s>-<n>  │
│    (.inputDerivation)                                                 │
│  ─ перезапись каждым билдом → старое замыкание становится transient   │
└──────────────────────────────────────────────────────────────────────┘
```

**Почему три слоя.** Модуль **vendor-agnostic** (R3): он не знает имён
`nixosConfigurations`/`devShells` consumer'а. Поэтому модуль отвечает за
«движок уборки + предоставление директории root'ов», а пиннинг конкретных
атрибутов — там, где эти имена и так открываются (`nix flake show` в actions).
Это точно ложится в существующий паттерн модуля: каждый sub-module владеет
своим куском, merge в один контейнер через `mkMerge`.

### 4.1. Layer A — size-threshold GC (default)

Заменяет блок `default.nix:166-176`. Сервис `nixtache-free-space` внутри
контейнера (модель — nix-community `free-space.bash`):

```bash
# startAt = cfg.gc.size.interval (default "hourly")
# проверяем файловую систему стора (relocated = /nix), а не корень контейнера
while :; do
  used=$(($(stat -f --format="100-(100*%a/%b)" /nix)))
  if [ "$used" -gt "${toString cfg.gc.size.diskThresholdPercent}" ]; then
    nix-store --gc --max-freed ${cfg.gc.size.maxFreePerRun}
  else
    break
  fi
done
```

Свойства:
- **GC срабатывает только при нехватке места** — пока диск свободен, стор не
  трогается (R2 не нарушает R1: пиннинг защищает нужное, а transient копится,
  пока есть место).
- **`--max-freed`** ограничивает длительность одного прохода; цикл повторяется,
  пока заполнение > порога (или собирать больше нечего).
- **`nix-store --gc`, а не `nix-collect-garbage`** — намеренно (как у
  nix-community): не трогаем profile-generations (внутри контейнера профили
  меняются редко — только при передеплое самого контейнера). Профили
  опционально подрезаются отдельно (§4.4).

### 4.2. Reactive in-build GC (`min-free`/`max-free`)

Поверх scheduled-сервиса — реактивная защита: если прямо во время билда свободное
место падает ниже `min-free`, nix-daemon сам запускает сборку мусора до `max-free`
(или пока мусор не кончится). Никакой scheduled-таймер тут не поможет —
защита встроена в daemon:

```nix
nix.settings.min-free = cfg.gc.size.minFree;   # default "1G"
nix.settings.max-free = cfg.gc.size.maxFree;   # default "50G"
```

### 4.3. Детерминированные `keep-*`

```nix
nix.settings.keep-outputs    = lib.mkForce false;  # R7: иначе GC бессилен
nix.settings.keep-derivations = true;              # default: дёшево, полезно для трассировки
```

`keep-outputs = true` — частый анти-паттерн («оставим всё, что когда-либо
собирали»): он сохраняет output каждой retained-деривации и стор растёт без
границ. nix-community force-выключает его даже на Hydra. Пиннинг конкретных
outputs (Layer C) — правильный способ сказать «это оставь».

### 4.4. Подрезка system-profile (опционально)

Внутри контейнера `/nix/var/nix/profiles/system` меняется редко (передеплой
контейнера). Подрезка не обязательна, но опция есть для полноты:

```bash
# если cfg.gc.size.pruneProfileAge != null:
nix-env --delete-generations ${cfg.gc.size.pruneProfileAge} \
        --profile /nix/var/nix/profiles/system
```

default `null` = не подрезать (контейнер молод, генераций мало).

### 4.5. `optimise`

nix-community: `auto-optimise-store = true` + `optimise.automatic = false`
(авто-оптимизация during-builds). Спека сохраняет текущий monthly-optimise, но
добавляет `auto-optimise-store = true` (дедуп при каждом добавлении в стор —
сильно экономит место на CI, где одинаковые пути переезжают между сборками).

---

## 5. Контракт опций: `services.nixtache.runner.gc.*`

Новый sub-модуль `modules/runner/gc.nix` (options + контейнерный вклад через
`mkMerge` в `containers.${cfg.containerName}.config`). `default.nix` теряет
блок `nix.{gc,optimise,settings}` и получает `imports += [ ./gc.nix ]`.

### 5.1. Верхний уровень

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `gc.enable` | `bool` | `true` | Мастер-выключатель. `false` → модуль не настраивает GC вообще (consumer управляет сам) |
| `gc.strategy` | `enum ["size" "time" "off"]` | `"size"` | R4: `size` — новый умный (§4); `time` — legacy `--delete-older-than` (поведение дос егодня); `off` — ничего не запускать (только reactive `min-free`/`max-free` если включены) |

### 5.2. `gc.size` (используется при `strategy == "size"`)

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `interval` | `str` (systemd OnCalendar) | `"hourly"` | `startAt` сервиса `nixtache-free-space` |
| `diskThresholdPercent` | `int` (0..100) | `80` | Запускать GC, когда заполнение `/nix` > порога |
| `maxFreePerRun` | `str` (bytes) | `"100G"` | `nix-store --gc --max-freed` за один проход |
| `minFree` | `str` | `"1G"` | `nix.settings.min-free` (reactive, §4.2) |
| `maxFree` | `str` | `"50G"` | `nix.settings.max-free` (reactive, §4.2) |
| `pruneProfileAge` | `nullOr str` | `null` | `nix-env --delete-generations <age>` для system-profile (§4.4); `null` = пропустить |

### 5.3. `gc.time` (используется при `strategy == "time"`, legacy)

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `dates` | `str` | `"*-*-01 04:00"` | То же, что сегодня (`nix.gc.dates`) |
| `deleteOlderThan` | `str` | `"30d"` | То же, что сегодня (`--delete-older-than`) |

> `strategy == "time"` воспроизводит сегодняшнее поведение 1:1 (R4: путь
> отката). При нём `min-free`/`max-free` всё равно проставляются (reactive
> защита уместна всегда), а `keep-outputs = mkForce false` — тоже.

### 5.4. `gc.keepBuilds` (Layer B — контракт пиннинга)

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `enable` | `bool` | `true` | Создать gcroots-директорию + экспортировать `NIXTACHE_GC_ROOTS_DIR` в jobs (§6) |
| `rootsDir` | `path` | `/nix/var/nix/gcroots/nixtache` | Директория под постоянными root'ами CI. Должна быть внутри `$NIX_STATE_DIR/gcroots/` relocated-стора (§9). Assertion проверяет префикс |

---

## 6. Layer B + C — пиннинг билдов

### 6.1. Что пинним (атрибуты consumer-флейка)

| Категория | Flake attr | Цель пиннинга |
|---|---|---|
| NixOS-конфиг | `.#nixosConfigurations.<name>.config.system.build.toplevel` | полный system closure |
| Девшелл | `.#devShells.<system>.<shell>.inputDerivation` | замыкание всех `buildInputs` шелла |

> **Почему `.inputDerivation` у девшелла.** `nix print-dev-env` (нынешняя
> проверка) не создаёт пиннабельного store-path — она рендерит окружение.
> `.inputDerivation` — это деривация, чьё замыкание = весь набор пакетов шелла;
> именно её пиннят nix-direnv и CI для «сохранить кэш девшелла». `print-dev-env`
> остаётся как smoke-check корректности, а `--out-link .inputDerivation`
> добавляется как шаг пиннинга.

### 6.2. Правила имён root'ов (стабильные, перезаписываемые)

Стабильное имя = root перезаписывается каждым билдом, старое замыкание теряет
root и становится transient → уходит в следующую уборку. **Нельзя** делать
per-commit/per-timestamp директории (мануал: GC-root нельзя
перемещать/переименовывать после `--add-root`; кроме того, это копит мусор).

| Категория | Имя root'а |
|---|---|
| NixOS-конфиг | `cfg-<name>` (напр. `cfg-server`) |
| Девшелл | `shell-<system>-<name>` (напр. `shell-x86_64-linux-vrc-shell`) |

Итог: ровно по одному root'у на атрибут, всегда «последний успешный билд».

### 6.3. Layer B — модуль (env-экспорт)

`gc.nix` добавляет tmpfiles-правило (в контейнерном конфиге):

```nix
systemd.tmpfiles.rules =
  lib.optional cfg.gc.keepBuilds.enable
    "d ${cfg.gc.keepBuilds.rootsDir} 0755 root root -";
```

`instances.nix` (единственный агрегатор `runner.envs`, строки 111-117)
добавляет **одну строку** — по той же модели, по которой туда уже едут
`HAS_SANDBOX_CAP`/`NIXTACHE_BOT_*` из option-derived значений:

```nix
envs = {
  # ...существующие NIXTACHE_* / HAS_SANDBOX_CAP...
  NIXTACHE_GC_ROOTS_DIR =
    lib.optionalString cfg.gc.keepBuilds.enable cfg.gc.keepBuilds.rootsDir;
};
```

> Умышленно держим пиннинг вне `gc.nix`'овой логики GC: env-экспорт — это
> «инфраструктура для actions», а агрегация env'ов уже живёт в `instances.nix`.
> Это сохраняет принцип «каждый sub-module владеет своим куском».

### 6.4. Layer C — composite-actions (пиннинг)

**`rebuild-configurations/action.yml`** — заменить `--no-link` на `--out-link`:

```bash
ROOTS="${NIXTACHE_GC_ROOTS_DIR:-}"
PIN_FLAG=""
if [ -n "$ROOTS" ] && [ -w "$(dirname "$ROOTS")" ] 2>/dev/null; then
  mkdir -p "$ROOTS"
  PIN_FLAG="--out-link $ROOTS/cfg-$config"
else
  PIN_FLAG="--no-link"   # R10: fallback на legacy, если env пуст или директория недоступна
fi
nix build $SANDBOX_FLAG $PIN_FLAG --print-build-logs \
  .#nixosConfigurations.$config.config.system.build.toplevel
```

**`rebuild-devshells/action.yml`** — добавить шаг пиннинга после `print-dev-env`:

```bash
# существующий smoke-check:
nix print-dev-env ".#devShells.$system.$shell" $SANDBOX_FLAG --print-build-logs
# новый шаг пиннинга (только если env задан):
ROOTS="${NIXTACHE_GC_ROOTS_DIR:-}"
if [ -n "$ROOTS" ] && [ -w "$(dirname "$ROOTS")" ] 2>/dev/null; then
  mkdir -p "$ROOTS"
  nix build $SANDBOX_FLAG --out-link "$ROOTS/shell-$system-$shell" \
    --no-link --print-build-logs \
    ".#devShells.$system.$shell.inputDerivation" || \
    echo "::warning::не удалось запиннить девшелл $shell ($system) — кэш не сохранится"
fi
```

> `|| echo "::warning::"` — пиннинг **никогда не валит сборку**: это оптимизация
> кэша, а не часть корректности. R10. Если `inputDerivation` недоступен для
  какого-то шелла (нестандартная конструкция) — предупреждение и работа дальше.

### 6.5. Что пиннинг гарантирует (и что — нет)

- **Гарантирует:** после любой уборки (size-based или ручной) замыкания
  последнего успешного билда каждого конфига/девшелла остаются в сторе →
  следующий CI-запуск их не пересобирает, а desktop/laptop продолжают
  substitut'ить их с `bincache`.
- **Не гарантирует:** историю сборок (rollback на сборку позавчерашнего commit'а).
  Хочешь историю — см. §8.2 (angrr/per-build профили).

---

## 7. Взаимодействие со спекой 0002 (транзитивный кэш)

- **Tier 1 (nginx pull-through)** хранит скачанное в nginx-кэше
  (`/var/cache/nixtache/mirror`) — **вне** nix-store → этот GC его не касается.
  Eviction'ом рулит `proxy_cache_path inactive/max_size` (опции 0002).
- **Tier 2 (`resign`)** импортирует upstream-пути **в стор** раннера
  (`nix copy --from <upstream>`). Эти пути попадают под действие GC из этой
  спеки: они не пиннутся Layer C (это не CI-outputs), значит уходят как
  transient при заполнении диска. Это **желаемое** поведение (Tier-2 кэш не
  должен вытеснять собственные сборки), но требует мониторинга, чтобы активно
  запрашиваемые upstream-пути не выкачивались повторно слишком часто. Кросс-ссылка
  добавится в 0002 §7.2 после утверждения этой спеки.

---

## 8. Альтернативы и roadmap

### 8.1. Почему не `keep-outputs = true`

См. §4.3 — эффективный запрет GC. nix-community force-выключает. Пиннинг
конкретных outputs — правильный инструмент.

### 8.2. Почему не `angrr` в v1

[`angrr`](https://github.com/linyinfeng/angrr) (`services.angrr` в nixpkgs,
Rust, «Auto Nix GC Roots Retention») — удаляет **устаревшие** auto GC-roots
(direnv, `result`-симлинки, старые profile-generations) по age/policy-правилам.
Он ортогонален этой спеке: мы перезаписываем root'ы каждым билдом, поэтому
устаревших root'ов **не копится** — angrr'у нечего чистить.

angrr становится полезным, если позже понадобится:
- **per-build retention** («держи последние N сборок каждого конфига» для
  rollback/bisect) — тогда root'ы плодятся (per-commit), и angrr
  (`temporary-root-policies` с `path-regex` + `period`) подрезает их по age;
- подрезка system/user-профилей по сложной политике (`keep-n-per-bucket`,
  `keep-since`) — вместо простого `pruneProfileAge` (§4.4).

Решение: v1 — без angrr (простота, одна зависимость меньше). Завести как
roadmap-опцию (`gc.retention = { enable = false; ... }` → включает `services.angrr`
внутри контейнера с политикой под gcroots-директорию nixtache), если
потребуется retention-by-age.

### 8.3. Почему не чисто time-based «длиннее» (`--delete-older-than 90d`)

Не решает задачу: при заполнении диска (большие Qt/closure'ы) 90 дней всё равно
наступают, и стор вычищается. Size-threshold (§4) — единственный подход,
который «убирает только когда надо».

---

## 9. Gotchas relocated store (важно для имплементации)

1. **GC-сервисы — внутри контейнера.** Они должны общаться с
   `nix-daemon-custom` (владелец `/srv/nix`). Если объявить сервис на хосте,
   он пойдёт к хостовому `/nix`, а не к relocated. Поэтому весь вклад `gc.nix`
   — в `containers.${cfg.containerName}.config` (как у `store.nix`).
2. **gcroots — внутри `$NIX_STATE_DIR/gcroots/`.** Коллектор сканирует только
   `$NIX_STATE_DIR/{gcroots,profiles}/` + `/proc/*`. Для relocated стора это
   `/nix/var/nix/gcroots/` внутри контейнера (=`/srv/nix/var/nix/gcroots/` на
   хосте). Поэтому default `rootsDir = /nix/var/nix/gcroots/nixtache`. Assertion
   (R6) проверяет, что путь начинается с `/nix/var/nix/gcroots/`.
3. **Диск проверяем по `/nix`, а не `/`.** Внутри nspawn `/` — корневой FS
   контейнера, а стор relocated на отдельном биндмаунте (`/srv/nix` → `/nix`).
   `stat -f /nix` видит файловую системы стора; `stat -f /` может показать
   другой (корневой) FS. n-community проверяет `/`, но у них всё на одном FS —
   у нас надо именно `/nix`.
4. **`store.path == "/"` (native store).** Тогда кастомный демон не запускается
   (см. `store.nix`), стор = системный `/nix`, и GC-сервисы/`min-free` всё
   равно корректны (работают против системного демона). gcroots лежат в
   стандартном `/nix/var/nix/gcroots/nixtache`. Ничего особого — просто
   работает.
5. **BindPaths в GC-сервис.** `nixtache-free-space` крутится внутри контейнера
   и для него `/nix` уже доступен (контейнерный root). Доп. `BindPaths` не нужны
   (в отличие от `gitea-runner-*`/`nix-serve`, которым бинд прописывает
   `store.nix`).

---

## 10. Контрольная точка (checkpoint)

> Спека — план инфраструктурного изменения GC раннера (затрагивает скорость CI
> и кэш для всего флота). **До правок модуля** (`gc.nix`/`instances.nix`/actions)
> жду явного подтверждения:
> - **Layer A**: `strategy = "size"` как новый default (size-threshold вместо
>   monthly time-based) — **да/нет**;
> - **Layer A**: сохранить `strategy = "time"` как legacy-путь отката — **да/нет**;
> - **Layer B+C**: пиннинг `nixosConfigurations` + `devShells.inputDerivation`
>   через `NIXTACHE_GC_ROOTS_DIR` — **да/нет**;
> - **default `diskThresholdPercent = 80` / `maxFreePerRun = 100G`** — уточнить
>   под реальный диск `/srv` сервера (Q3 в §12);
> - **`auto-optimise-store = true`** (§4.5) — включать в v1 или отложить;
> - **angrr** (§8.2) — отложить в roadmap (рекомендация) или завести сразу.

---

## 11. Тестовое покрытие (`tests/runner.nix`)

По правилу репо — каждая новая опция/поведение покрывается pure-eval сценарием:

| Сценарий | Что проверяем |
|---|---|
| `gc.strategy = "size"` (default) | внутри контейнера есть сервис `nixtache-free-space` с `startAt = "hourly"`; `nix.gc.automatic == false`; `nix.settings.{min-free,max-free}` проставлены; `keep-outputs == false` (mkForce); `auto-optimise-store == true` |
| `gc.size.diskThresholdPercent` / `maxFreePerRun` кастомные | значения попадают в скрипт `free-space` (через `deps = [ ExecStart ]` + grep, как уже сделано для `nix-daemon-storage` в конце `tests/runner.nix`) |
| `gc.strategy = "time"` (legacy) | `nix.gc.automatic == true`, `nix.gc.dates`/`options` из `gc.time.*`; сервиса `nixtache-free-space` нет; `keep-outputs` всё равно `mkForce false` |
| `gc.strategy = "off"` | ни `nix.gc.automatic`, ни `nixtache-free-space`; `min-free`/`max-free` могут быть включены отдельно |
| `gc.enable = false` | модуль не трогает `nix.gc`/`nix.settings.min-free`/`tmpfiles` вообще |
| `gc.keepBuilds.enable = true` (default) | tmpfiles-правило создаёт `rootsDir`; `NIXTACHE_GC_ROOTS_DIR` в `runner.envs` равен `rootsDir` |
| `gc.keepBuilds.enable = false` | tmpfiles-правила нет; `NIXTACHE_GC_ROOTS_DIR` пустой в envs |
| `gc.keepBuilds.rootsDir` вне `/nix/var/nix/gcroots/` | assertion-fail «rootsDir must live under $NIX_STATE_DIR/gcroots (relocated store)» |
| `store.path = "/"` + `gc.strategy = "size"` | `free-space` всё равно объявлен (native store); default `rootsDir` остаётся валидным |
| env-экспорт в multi-instance | `NIXTACHE_GC_ROOTS_DIR` присутствует в envs **каждого** instance (не только default) |

---

## 12. Артефакты и этапы

### Артефакты в `nixtache`

| Артефакт | Назначение | Статус |
|---|---|---|
| `modules/runner/gc.nix` | Опции `gc.*` + контейнерный вклад (`free-space`/tmpfiles/`nix.settings`/`nix.gc`) | НОВОЕ |
| `modules/runner/default.nix` | Убрать блок `nix.{gc,optimise,settings}` (строки 166-176) → `imports += [ ./gc.nix ]` | правка |
| `modules/runner/instances.nix` | + 1 строка в `runner.envs`: `NIXTACHE_GC_ROOTS_DIR` (§6.3) | правка |
| `.forgejo/actions/rebuild-configurations/action.yml` | `--no-link` → `--out-link $ROOTS/cfg-<name>` + fallback (§6.4) | правка |
| `.forgejo/actions/rebuild-devshells/action.yml` | + шаг пиннинга `.inputDerivation` (§6.4) | правка |
| `tests/runner.nix` | + сценарии GC (§11) | правка |
| `packages.optionsMarkdown` | авто-включит `services.nixtache.runner.gc.*` | без правок |
| `README.md` / `AGENTS.md` | раздел «Smart GC» + consumer-заметка (поведение по умолчанию изменилось) | правка |

### Этапы

1. **Контракт модуля** — `gc.*` опции, assertion'ы (`rootsDir` prefix, `gc.enable`),
   тесты pure-eval (§11).
2. **GC-движок** — `gc.nix` с `free-space`-сервисом + `min-free`/`max-free` +
   `keep-outputs = mkForce false`; вынести существующий `nix.gc`/`optimise` из
   `default.nix`.
3. **Env-экспорт** — `instances.nix`: `NIXTACHE_GC_ROOTS_DIR`; tmpfiles.
4. **Actions-пиннинг** — правка `rebuild-configurations`/`rebuild-devshells`
   (с fallback на `--no-link`).
5. **Стенд** — передеплой сервера, прогон CI, проверить:
   - `nixtache-free-space.service` отрабатывает по `systemctl`;
   - `ls /nix/var/nix/gcroots/nixtache/` содержит `cfg-*`/`shell-*` после CI;
   - принудительный `nix-store --gc` не удаляет пинненные замыкания;
   - следующий CI-запуск переиспользует кэш (быстрый билд).
6. *(Roadmap)* **angrr/retention** — если понадобится история сборок (§8.2).

---

## 13. Открытые вопросы

| Q | Вопрос | Вариант |
|---|---|---|
| Q1 | `strategy = "size"` как default или `time` (без сюрпризов)? | Рекомендую `size` (решает задачу); `time` остаётся как legacy-флаг |
| Q2 | Default `keepBuilds.enable = true`? | Да — пиннинг безопасен (перезапись, не валит сборку) и решает R1 |
| Q3 | Реальные значения под диск сервера (`/srv`): `diskThresholdPercent`, `maxFreePerRun`, `min-free`/`max-free` | Уточнить по месту (размер `/srv/bincache`) — дефолты 80 % / 100G / 1G / 50G могут быть велики/малы |
| Q4 | Пиннить ли `.inputDerivation` при `--no-sandbox` (legacy/привилегированный раннер)? | Да — пиннинг не зависит от sandbox; `.drv` собирается в обоих режимах |
| Q5 | `auto-optimise-store = true` в v1? | Рекомендую да (дёшево, экономит место); на ZFS/BTRFS может быть избыточно (nix-community force-off на build02) — уточнить FS сервера |
| Q6 | Подрезка `system-profile` внутри контейнера (`pruneProfileAge`) | default `null` (профиль меняется редко); включить если заметим рост генераций |
| Q7 | angrr сейчас или roadmap? | Roadmap (§8.2) — пока перезапись root'ов делает retention ненужным |

---

### Ссылки (ресерч)

- nix-community/infra:
  - `modules/shared/nix-daemon.nix` (base `min-free`/`max-free`/`gc.options`) — <https://github.com/nix-community/infra/blob/master/modules/shared/nix-daemon.nix>
  - `modules/nixos/common/builder.nix` (disable auto-gc on builders) — <https://github.com/nix-community/infra/blob/master/modules/nixos/common/builder.nix>
  - `modules/shared/free-space.bash` (size-threshold loop) — <https://github.com/nix-community/infra/blob/master/modules/shared/free-space.bash>
  - `modules/nixos/hydra.nix` (`keep-outputs = mkForce false`) — <https://github.com/nix-community/infra/blob/master/modules/nixos/hydra.nix>
- Nix manual:
  - `nix-collect-garbage` (`--delete-older-than` чистит только profile-gens) — <https://nixos.org/manual/nix/stable/command-ref/nix-collect-garbage.html>
  - `nix-store --gc` (`--add-root`, `--max-freed`, достижимость из root'ов) — <https://nixos.org/manual/nix/stable/command-ref/nix-store/gc.html>
  - `nix.conf` (`keep-derivations`/`keep-outputs`/`min-free`/`max-free`) — <https://nixos.org/manual/nix/stable/command-ref/conf-file.html>
- NixOS upstream:
  - `nix.gc` module (`nix-collect-garbage ${cfg.options}`) — <https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/misc/nix-gc.nix>
- angrr (roadmap-ссылка):
  - `linyinfeng/angrr` — <https://github.com/linyinfeng/angrr>
  - nixpkgs module `services.angrr` — <https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/misc/angrr.nix>

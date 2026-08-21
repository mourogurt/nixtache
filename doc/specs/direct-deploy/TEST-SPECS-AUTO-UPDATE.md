# TEST-SPECS-AUTO-UPDATE — детальные тест-спеки по 09-auto-update.md

> **Назначение:** раскрыть модуль `services.nixtache.auto-update.*`
> (`09-auto-update.md`) до уровня реализуемых тест-кейсов: точные Nix-опции,
> точные assertions, тип теста, KVM-маркировка, переиспользование фикстур.
> Другой агент реализует `modules/auto-update/default.nix` + файлы в `tests/`
> по этой спеке.
>
> **Подход:** conformance / исполняемая спека (как `TEST-SPECS.md` §0). Все
> кейсы — 🆕 **NEW MODULE (contract)**: модуля нет, тесты определяют его
> поведение. До реализации — красные; цель имплементации — зелёные.
>
> **Скоуп:** ВСЕ опции §4 спеки 09, оба пути (flake / ab-image), derive-логика
> `method = "auto"`, assert-матрица A1–A8, precedence-правила (§8 спеки 09),
> observability-артефакты (§11 спеки 09).
>
> **Дата:** 2026-08-10. Сверено с `09-auto-update.md` и исходниками
> `modules/{deploy-target,ab-image,runner}` на момент написания.

---

## 0. Конвенции

Действуют §0 `TEST-SPECS.md` без изменений (статусы ✅/🆕/🔧/📋, типы тестов,
каркас pure-eval, KVM-маркер `requiredSystemFeatures = [ "kvm" ]`, проводка в
`flake.nix` `checks.<system>`). Ниже — только auto-update-специфика.

### 0.1. Имена и юниты под тестом

| Артефакт | Имя |
|---|---|
| Опции | `services.nixtache.auto-update.*` |
| Poll-таймер | `nixtache-auto-update.timer` |
| Poll-сервис | `nixtache-auto-update.service` |
| Reboot-таймер (только `rebootPolicy = "window"`) | `nixtache-auto-update-reboot.timer` |
| Marker отложенного reboot | `/var/lib/nixtache/reboot-pending` |
| Pointer (общий с CI) | `/var/lib/nixtache/pending-system` |
| Журнальный префикс | `nixtache-auto-update:` |

### 0.2. Базовые mkHost-конструкторы для сценариев

По образцу `tests/deploy-target.nix` / `tests/runner.nix`. Три базы:

- **`mkHostFlake`** — `baseModule` + `self.nixosModules.deploy-target` +
  `self.nixosModules.auto-update` (НОВЫЙ) + `services.nixtache.auto-update =
  { enable = true; flake.url = "..."; }` + extra. Аналог non-OTA таргета.
- **`mkHostAb`** — `baseModule` + `deploy-target` + `auto-update` +
  `services.nixtache.deploy-target.ab.enable = true` + stub-правки, нужные для
  чистого eval без полного A/B prep: `systemd.sysupdate.enable = true` +
  `boot.loader.systemd-boot.bootCounting.enable = true` (те же stub'ы, что
  `scenarioAb` в `tests/deploy-target.nix`). Для сценариев с источником —
  `deploy-target.ab.partitions = { enable = true; source = "..."; ... }`.
- **`mkHostGating`** — `mkHostAb` + `ab.gating = true` + `forgejoApiTokenFile`
  + stub опции `services.nixtache.runner.forgejoPort` (тот же приём, что §1а.4
  `TEST-SPECS.md`: gating-скрипт читает опцию runner-модуля, которого в VM/хосте
  нет).

### 0.3. Фикстуры

- Pure-eval: фикстур не нужно (пути-заглушки `/dev/null`, `pkgs.writeText`).
- VM-тесты flake-пути: локальный bare git-репозиторий с минимальным
  NixOS-flake'ом, отдаваемый тестовым httpd/nginx на node `deployer` (по образцу
  nginx-staging в `tests/ab-deploy-e2e.nix`). **Не** дублировать GPG/SSH
  fixture'ы — брать из `tests/ab-fixture.nix`, если понадобятся.
- VM-тесты ab-пути: `tests/ab-fixture.nix` `mkAppliance` + provision-модуль,
  ровно как `B1`-серия (`TEST-SPECS.md` §1а.3): target на
  `ab.partitions` (autoInit, /dev/vdb), staging через
  `system.extraDependencies`.

---

## 1. Pure-eval contract tests — wiring опций (AU-1…AU-14)

> Файл: `tests/auto-update.nix` (🆕). Каркас §0.3 TEST-SPECS.md: `mkHost*`,
> `checks`, агрегация в `scenarios`, `pkgs.runCommand` с отчётом. Каждый кейс —
> один сценарий. Ниже `au = config.services.nixtache.auto-update` (evaluated
> config хоста), `svc = config.systemd.services."nixtache-auto-update"`,
> `tmr = config.systemd.timers."nixtache-auto-update"`.

### AU-1 — disabled by default (no units)

**ID:** AU-1. **Приоритет:** P0.
**Setup:** `mkHostFlake` с `auto-update.enable = false` (или не задан).
**Assertions:**
- `noService`: `!(config.systemd.services ? "nixtache-auto-update")`.
- `noTimer`: `!(config.systemd.timers ? "nixtache-auto-update")`.
- `noRebootTimer`: `!(config.systemd.timers ? "nixtache-auto-update-reboot")`.

### AU-2 — enable → timer+service wired (flake-путь)

**ID:** AU-2. **Приоритет:** P0.
**Setup:** `mkHostFlake` (enable, `flake.url = "git+https://example.invalid/org/repo.git"`).
**Assertions:**
- `servicePresent`: `config.systemd.services ? "nixtache-auto-update"`.
- `serviceOneshot`: `svc.serviceConfig.Type == "oneshot"`.
- `timerPresent`: `config.systemd.timers ? "nixtache-auto-update"`.
- `timerWanted`: `lib.elem "timers.target" tmr.wantedBy`.
- `timerCalendar`: `tmr.timerConfig.OnCalendar == "daily"` (default `dates`).
- `timerDelay`: `tmr.timerConfig.RandomizedDelaySec == "1h"` (default).
- `timerPersistent`: `tmr.timerConfig.Persistent == true` (default).

### AU-3 — schedule options propagate

**ID:** AU-3. **Приоритет:** P1.
**Setup:** `mkHostFlake` + `dates = "Mon 03:30"`, `randomizedDelaySec = "30min"`, `persistent = false`.
**Assertions:**
- `calendarSet`: `tmr.timerConfig.OnCalendar == "Mon 03:30"`.
- `delaySet`: `tmr.timerConfig.RandomizedDelaySec == "30min"`.
- `persistentOff`: `tmr.timerConfig.Persistent == false`.

### AU-4 — flake.* wiring into the service script

**ID:** AU-4. **Приоритет:** P0.
**Setup:** `mkHostFlake` + `flake = { url = "git+https://example.invalid/o/r.git";
ref = "release"; configuration = "myhost"; flags = [ "--refresh" ]; }`,
`networking.hostName = "other"`.
**Assertions (на `svc.script`):**
- `buildTarget`: script содержит
  `git+https://example.invalid/o/r.git?ref=release#nixosConfigurations.myhost.config.system.build.toplevel`
  (ref дописан как `?ref=` для git-URL; `configuration` победил hostName).
- `flagsInScript`: script содержит `--refresh`.
- `pointerWrite`: script содержит `/var/lib/nixtache/pending-system` (запись pointer).
- `applyTrigger`: script содержит `systemctl start nixtache-apply.service`
  (активация через apply-unit — КЛЮЧЕВОЙ контракт §5 спеки 09).
- `noNixosRebuild`: `!(lib.hasInfix "nixos-rebuild" svc.script)` — raw
  nixos-rebuild запрещён (§5).

### AU-5 — configuration defaults to hostName

**ID:** AU-5. **Приоритет:** P1.
**Setup:** `mkHostFlake`, `flake.configuration = null`, `networking.hostName = "lap"`.
**Assertions:** `hostNameUsed`: `lib.hasInfix "nixosConfigurations.lap." svc.script`.

### AU-6 — flake.ref null → no ?ref= appended

**ID:** AU-6. **Приоритет:** P2.
**Setup:** `mkHostFlake`, `flake.ref = null`, url без ref.
**Assertions:** `noRefSuffix`: script НЕ содержит `?ref=`.

### AU-7 — sshPrivateKeyFile → LoadCredential + GIT_SSH_COMMAND

**ID:** AU-7. **Приоритет:** P1.
**Setup:** `mkHostFlake` + `flake.sshPrivateKeyFile = /dev/null`.
**Assertions:**
- `loadCredential`: `svc.serviceConfig.LoadCredential` содержит элемент с
  `/dev/null` (credential, напр. `auto_update_ssh_key:/dev/null`).
- `gitSshCommand`: `lib.hasInfix "GIT_SSH_COMMAND" svc.script` (или
  `svc.environment`) и ссылка на `$CREDENTIALS_DIRECTORY`.
**Контр-сценарий (тот же кейс):** `sshPrivateKeyFile = null` → LoadCredential
отсутствует, GIT_SSH_COMMAND не задаётся.

### AU-8 — method derive: auto → flake

**ID:** AU-8. **Приоритет:** P0.
**Setup:** `mkHostFlake` с `method = "auto"` (default), БЕЗ ab-модулей.
**Assertions:**
- `flakePath`: script содержит `nix build` и НЕ содержит
  `systemd-sysupdate.service` (ветка flake).
- `rebootNeverDefault`: script НЕ содержит `systemctl reboot` (rebootPolicy
  default "never").

### AU-9 — method derive: auto → ab-image (по deploy-target.ab.enable)

**ID:** AU-9. **Приоритет:** P0.
**Setup:** `mkHostAb` (ab.enable=true) + `auto-update.enable = true`,
`method = "auto"`. `flake.url` НЕ задан (проверка, что A3 не требуется на
ab-пути).
**Assertions:**
- `abPath`: script содержит `systemctl start systemd-sysupdate.service`.
- `noBuild`: script НЕ содержит `nix build` (flake.* игнорируются на ab-пути).
- `journalDetect`: script содержит `journalctl -u systemd-sysupdate` (детект
  «installed» для reboot-политики, §6.1 спеки 09).

### AU-10 — method derive: auto → ab-image (по ab-image.enable)

**ID:** AU-10. **Приоритет:** P1.
**Setup:** `mkHostFlake` + импорт `self.nixosModules.ab-image` +
`services.nixtache.ab-image = { enable = true; imageId = "t"; }` +
stub `systemd.sysupdate.enable = true` (ab-image его и так ставит) +
`auto-update.enable = true`. Без `deploy-target.ab.enable`.
**Assertions:** derive дал `ab-image`: script содержит
`systemd-sysupdate.service`, не содержит `nix build`.
> **Примечание реализующему:** ab-image тянет appliance-профиль
> (`nix.enable = false`) — это валидный eval, просто проверка derive по второму
> индикатору (§3 спеки 09: `abPresent` = ab.enable || ab-image.enable).

### AU-11 — explicit method overrides derive (обе стороны)

**ID:** AU-11. **Приоритет:** P1.
**Setup A:** `mkHostAb` + `method = "flake"` + `flake.url` задан.
**Assertions A:** `explicitFlake`: script содержит `nix build`, не содержит
`systemd-sysupdate.service`.
**Setup B:** `mkHostFlake` (без ab) + `method = "ab-image"` + stub
`systemd.sysupdate.enable = true`.
**Assertions B:** `explicitAb`: script содержит `systemd-sysupdate.service`.

### AU-12 — rebootPolicy = "if-needed" (flake: kernel compare; ab: immediate)

**ID:** AU-12. **Приоритет:** P1.
**Setup A (flake):** `mkHostFlake` + `rebootPolicy = "if-needed"`.
**Assertions A:**
- `kernelCompare`: script ссылается на `/run/booted-system` И
  `/run/current-system` (сравнение ядер).
- `rebootCall`: `lib.hasInfix "systemctl reboot" svc.script`.
**Setup B (ab):** `mkHostAb` + `rebootPolicy = "if-needed"`.
**Assertions B:**
- `immediateReboot`: `lib.hasInfix "systemctl reboot" svc.script`.
- `noPendingMarker`: script НЕ пишет `/var/lib/nixtache/reboot-pending`.

### AU-13 — rebootPolicy = "window" → marker + reboot-timer

**ID:** AU-13. **Приоритет:** P1.
**Setup:** `mkHostFlake` + `rebootPolicy = "window"` +
`rebootWindow = { start = "02:00"; end = "05:00"; }`.
**Assertions:**
- `markerTouch`: `lib.hasInfix "/var/lib/nixtache/reboot-pending" svc.script`.
- `noDirectReboot`: script НЕ содержит непосредственный `systemctl reboot`
  (reboot делает reboot-timer'ов сервис).
- `rebootTimerPresent`: `config.systemd.timers ? "nixtache-auto-update-reboot"`.
- `rebootTimerCalendar`:
  `config.systemd.timers."nixtache-auto-update-reboot".timerConfig.OnCalendar == "02:00"`.
- `rebootTimerWanted`: `lib.elem "timers.target"
  config.systemd.timers."nixtache-auto-update-reboot".wantedBy`.
**Контр-сценарий:** `rebootPolicy = "never"` → reboot-timer отсутствует
(покрыто AU-1/AU-8).

### AU-14 — gating host: ab.poll derive + no-op маркер

**ID:** AU-14. **Приоритет:** P1.
**Setup:** `mkHostGating` (gating=true) + `auto-update.enable = true`,
`rebootPolicy = "never"` (иначе A6).
**Assertions:**
- `pollDerivedFalse`: script содержит маркер `ci-driven` (no-op ветка §6.2
  спеки 09) и НЕ содержит активный `systemctl start systemd-sysupdate.service`
  вне комментария/echo.
- `explicitPollTrue`: контр-сценарий `ab.poll = true` на том же gating-хосте →
  script содержит `systemctl start systemd-sysupdate.service` (override
  возможен — опция есть, хоть default и false).

---

## 2. Pure-eval assert-matrix tests (AU-15…AU-22 → A1…A8)

> Каждый кейс: `builtins.tryEval (...).config.system.build.toplevel.outPath` —
> ожидаем `!result.success` (каркас `scenarioAutoOffAssert` из
> `tests/deploy-target.nix`). Плюс проверка текста сообщения через
> `host.config.assertions` (find by `assertion == false`, `lib.hasInfix`
> по `message`). Файл: тот же `tests/auto-update.nix`.

| ID | Assert (спека 09 §7) | Setup | Assertion (что проверить) |
|---|---|---|---|
| AU-15 | A1 | `mkHostFlake` + `system.autoUpgrade.enable = true` | `!tryEval`; message содержит `system.autoUpgrade` |
| AU-16 | A2 | auto-update enable, method flake, БЕЗ импорта deploy-target (голый baseModule + auto-update) | `!tryEval`; message содержит `deploy-target` / `nixtache-apply` |
| AU-17 | A3 | `mkHostFlake`, `flake.url = null` | `!tryEval`; message содержит `flake.url` |
| AU-18 | A4 | method ab-image, `systemd.sysupdate.enable = false`, source не задан нигде | `!tryEval`; message содержит `systemd.sysupdate` |
| AU-19 | A5 | `rebootPolicy = "window"`, `rebootWindow.start == rebootWindow.end == "02:00"` | `!tryEval`; message содержит `rebootWindow` |
| AU-20 | A6 | `mkHostGating` + `rebootPolicy = "if-needed"` | `!tryEval`; message содержит `gating` / `rebootPolicy` |
| AU-21 | A7 (warning, не fail) | `mkHostAb` + transfers с `Transfer.Reboot = "yes"` (через `systemd.sysupdate.transfers` override) | eval **проходит** (`tryEval.success`); warning эмитится — проверка: `builtins.trace`-ловушка невозможна, поэтому зафиксировать как документированный `lib.warn`-контракт; smoke: host eval'ится, AU-9-assertions валидны. **Маркер 📋/partial** — поведенческий контроль warning'а только глазами в отчёте (nix не экспонирует warnings). |
| AU-22 | A8 | `mkHostFlake` (без ab) + `method = "ab-image"` (explicit), `systemd.sysupdate.enable = false` | `!tryEval`; message содержит `ab-image` (explicit без индикаторов — fail по A8 раньше A4, либо оба сообщения допустимы: проверять наличие ЛЮБОГО из них) |

> **Граница A2:** `mkHostFlake` БЕЗ deploy-target должен фейлиться **только**
> из-за auto-update (A2), а не из-за отсутствия опции — модуль обращается к
> `config.services.nixtache.deploy-target` через `hasAttr`/`or`-guard'ы
> (паттерн `ab-provision.nix` строки 51–57). AU-16 это и проверяет: ошибка —
> assertion, не `attribute 'deploy-target' missing`.

---

## 3. Pure-eval precedence/idempotency tests (AU-23…AU-25)

> §8 спеки 09. Проверяется текстом скрипта (pure-eval) + поведением (§4 VM).

### AU-23 — CI-pending skip branch

**ID:** AU-23. **Приоритет:** P0.
**Setup:** `mkHostFlake`.
**Assertions (на `svc.script`):**
- `pendingCheck`: script содержит проверку существования
  `/var/lib/nixtache/pending-system` ДО записи pointer.
- `skipMarker`: script содержит журнальный маркер skip (напр.
  `CI deploy pending — skipping`).

### AU-24 — unchanged-toplevel no-op branch

**ID:** AU-24. **Приоритет:** P1.
**Setup:** `mkHostFlake`.
**Assertions:**
- `currentSystemCompare`: script содержит `/run/current-system` (сравнение
  built vs current до записи pointer).
- `alreadyMarker`: маркер no-op (напр. `already at`).

### AU-25 — atomic pointer write

**ID:** AU-25. **Приоритет:** P2.
**Setup:** `mkHostFlake`.
**Assertions:** script пишет pointer через временный файл + `mv`
(`lib.hasInfix "pending-system.tmp"` или эквивалент tmp+rename рядом с
`pending-system`) — не прямой `echo > pending-system`.

---

## 4. runNixOSTest behavioral tests (AU-F1…, AU-A1…)

> Тяжёлые, `requiredSystemFeatures = [ "kvm" ]`. Файлы:
> `tests/auto-update-flake-vm.nix` (AU-F*), `tests/auto-update-ab-vm.nix` (AU-A*).

### 4.1. AU-F1 — flake timer → apply unit активирует новый toplevel

**ID:** AU-F1. **Цель:** end-to-end non-OTA: таймерный сервис собирает flake из
ЛОКАЛЬНОГО git-репо, пишет pointer, `nixtache-apply.service` активирует,
criticalUnits probe проходит, /run/current-system меняется.
**Тип:** runNixOSTest (1 нода `target` + локальный bare repo на ней же или на
`deployer`-ноде с plain httpd). **KVM:** ✅. **Приоритет:** P0.

**Setup:**
- Node `target`: `mkHostFlake`-эквивалент: `deploy-target` (без deployUser —
  таймер root, SSH не нужен) + `auto-update = { enable = true; flake.url =
  "/srv/test-flake"; flake.flags = [ "--no-write-lock-file" ];
  criticalUnits = [ "multi-user.target" ] (через deploy-target); }`.
- Локальный flake-фикстур: два коммита в `/srv/test-flake` — v1 (базовый
  toplevel == текущей VM) и v2 (v1 + `environment.systemPackages = [ pkgs.hello ]`).
  VM собирается ИЗ v1; перед прогоном сервиса repo-HEAD переводится на v2.
- Использовать `virtualisation.additionalPaths` / предсобранные closures, чтобы
  `nix build` внутри VM не тянул сеть (hermetic: flake с `inputs = {};`,
  toplevel из той же nixpkgs, что VM).

**Действие:** `target.succeed("systemctl start nixtache-auto-update.service")`
(прямой старт — семантика таймера; сам таймер покрыт pure-eval AU-2/3).

**Assertions:**
- `pointerConsumed`: после успеха `/var/lib/nixtache/pending-system` отсутствует
  (apply-unit его удалил).
- `helloActive`: `hello` доступен в PATH (`target.succeed("hello")`) — новый
  toplevel активирован.
- `profileSwitched`: `readlink /nix/var/nix/profiles/system` != исходный путь.
- `applyJournal`: `journalctl -u nixtache-apply` содержит `activated` (05-маркер).
- `autoUpdateJournal`: `journalctl -u nixtache-auto-update` содержит `nixtache-auto-update:`.

### 4.2. AU-F2 — unchanged flake → no-op (идемпотентность)

**ID:** AU-F2. **Цель:** повторный прогон при неизменном repo — без записи
pointer и без запуска apply-unit (AU-24 в рантайме).
**Тип:** runNixOSTest (продолжение AU-F1 на той же VM). **KVM:** ✅. **Приоритет:** P1.

**Setup/Действие:** после AU-F1 — второй
`systemctl start nixtache-auto-update.service` без смены repo.

**Assertions:**
- `noPointer`: pointer так и не появился (`test ! -f`).
- `noopMarker`: journal второго прогона содержит no-op маркер (`already at`).
- `noApplyRun`: счётчик запусков `nixtache-apply.service`
  (`systemctl show -p NRestarts` / journal) не вырос.

### 4.3. AU-F3 — CI pending → auto-update skips (precedence §8.2)

**ID:** AU-F3. **Цель:** если pointer уже существует (CI deploy в полёте),
auto-update выходит, не перезаписывая его.
**Тип:** runNixOSTest (та же VM). **KVM:** ✅. **Приоритет:** P1.

**Действие:** вручную `echo "/nix/store/<v1-path>" > /var/lib/nixtache/pending-system`
(имитация CI-stage), затем `systemctl start nixtache-auto-update.service`.

**Assertions:**
- `skipMarker`: journal содержит skip-маркер (`CI deploy pending`).
- `pointerIntact`: содержимое pointer НЕ изменилось (всё ещё v1-path).
- `noApply`: apply-unit не запускался этим прогоном.
- Cleanup: `rm pointer` в конце (не ломать соседние кейсы на той же VM).

### 4.4. AU-F4 — apply probe fail → rollback (Tier-1 через auto-update)

**ID:** AU-F4. **Цель:** auto-update сохраняет rollback-историю: v2-flake ломает
criticalUnit → apply-unit откатывает профиль → auto-update service exits 1.
**Тип:** runNixOSTest. **KVM:** ✅. **Приоритет:** P1.

**Setup:** как AU-F1, но `criticalUnits = [ "nonexistent.service" ]` (probe
гарантированно фейлится) + `healthCheckTimeout = 30` (быстрый тест).

**Assertions:**
- `serviceFailed`: `target.fail("systemctl start nixtache-auto-update.service")`.
- `profileReverted`: `readlink /nix/var/nix/profiles/system` == исходный путь.
- `rollbackMarker`: `journalctl -u nixtache-apply` содержит `reverting` /
  `rolling back` (05-маркеры).

### 4.5. AU-F5 — rebootPolicy = "if-needed" ребутит при смене ядра

**ID:** AU-F5. **Цель:** после apply с новым ядром (`/run/booted-system` !=
`/run/current-system`) auto-update инициирует reboot.
**Тип:** runNixOSTest. **KVM:** ✅. **Приоритет:** P2.
> **Примечание:** сменить ядро в тестовом flake дорого (пересборка). Приём:
> v2-flake задаёт `boot.kernelPackages = pkgs.linuxPackages` (другой набор уже
> в binary cache фикстуры) ИЛИ — дешевле — подменить детект: v2-flake добавляет
> `system.extraDependencies`… **Допустимо** сымитировать различие ядер,
> переписав symlink `/run/booted-system` нельзя (ro?). Реализующему: если
> честная смена ядра слишком тяжела, пометить кейс 📋 partial и покрыть ветку
> pure-eval (AU-12A) + ручным тестом.

**Assertions:**
- `rebootHappened`: VM уходит в reboot (test driver ловит disconnect/reconnect,
  `machine.wait_for_unit("multi-user.target")` после).
- `newKernel`: после reboot `uname -r` == ядро v2.

### 4.6. AU-A1 — ab timer → sysupdate тянет образ в слот B

**ID:** AU-A1. **Цель:** end-to-end OTA: таймерный сервис триггерит
`systemd-sysupdate`, staged-образ записывается в свободный слот, GPT label
меняется. По сути `B1` из `TEST-SPECS.md` §1а.3, но триггер —
`nixtache-auto-update.service` вместо прямого `systemctl start systemd-sysupdate`.
**Тип:** runNixOSTest (1 нода). **KVM:** ✅. **Приоритет:** P0.

**Setup:** как `B1`: provision-модуль (`ab.partitions = { enable = true;
autoInit = true; slotSize = "512M"; source = "/var/lib/nixtache/ab-stage/abtest";
bootTarget = "/var/lib/nixtache/ab-slots/"; slot_a/slot_b type=partition
storage=/dev/vdb; }`) + `auto-update.enable = true` (derive → ab-image).
v2 sysupdate-package через `system.extraDependencies`; testScript копирует
содержимое пакета в staging-dir.

**Действие:** `systemctl start nixtache-auto-update.service`.

**Assertions:**
- `slotWritten`: `sgdisk -p /dev/vdb | grep nix-store_2`.
- `efiWritten`: `test -f /var/lib/nixtache/ab-slots/abtest_2.efi`.
- `sysupdateJournal`: `journalctl -u systemd-sysupdate | grep "Successfully installed"`.
- `autoUpdateJournal`: `journalctl -u nixtache-auto-update` содержит маркер
  триггера sysupdate.
- `noReboot` (rebootPolicy default never): VM не ребутнулась —
  `uptime`/`systemctl show -p ExecMainStartTimestamp multi-user.target` не
  обнулился, либо драйвер не видел disconnect.

### 4.7. AU-A2 — ab timer без нового образа → no-op

**ID:** AU-A2. **Цель:** staging пуст (нет старшей версии) → sysupdate отвечает
«nothing to do», auto-update exits 0, слоты не тронуты, reboot не инициирован
даже при `rebootPolicy = "if-needed"`.
**Тип:** runNixOSTest (та же VM после AU-A1). **KVM:** ✅. **Приоритет:** P1.

**Действие:** второй `systemctl start nixtache-auto-update.service` (версия 2
уже установлена, новой нет) с `rebootPolicy = "if-needed"`.

**Assertions:**
- `exitZero`: сервис завершился успешно.
- `noNewSlot`: `sgdisk -p /dev/vdb` без изменений (нет `nix-store_3`).
- `noReboot`: VM не ребутнулась.

### 4.8. AU-A3 — gating host: auto-update no-op (ci-driven маркер)

**ID:** AU-A3. **Цель:** на gating-хосте auto-update НЕ стартует sysupdate
(§6.2 спеки 09) — канал CI-driven; образ остаётся неприменённым до
gating-сигнала.
**Тип:** runNixOSTest (1 нода, `mkHostGating`-эквивалент + mock Forgejo API по
образцу B2 §1а.4). **KVM:** ✅. **Приоритет:** P2.

**Setup:** AU-A1 + `ab.gating = true` + `forgejoApiTokenFile` + mock API
(возвращает `[]`) + `rebootPolicy = "never"` (A6).

**Действие:** staged v2 присутствует; `systemctl start nixtache-auto-update.service`.

**Assertions:**
- `ciDrivenMarker`: journal содержит `ci-driven` маркер.
- `noSysupdateRun`: `journalctl -u systemd-sysupdate --since` НЕ содержит
  нового install; `sgdisk -p /dev/vdb | grep -c nix-store_2` == 0.
- `pendingUntouched`: `/var/lib/nixtache/ab-pending` НЕ создан auto-update'ом
  (это право CI; auto-update его не трогает — ни touch, ни rm).

### 4.9. AU-A4 — ab timer + signed image (Verify=yes) принимается

**ID:** AU-A4. **Цель:** auto-update-триггер сохраняет верификацию: подписанный
образ через timer-pull применяется (positive control; негативные случаи —
чужая зона, покрыты C1–C3 в `TEST-SPECS.md` §1а.7 прямым sysupdate).
**Тип:** runNixOSTest (как AU-A1 + pubring из `ab-fixture.nix`). **KVM:** ✅.
**Приоритет:** P2.

**Setup:** AU-A1 + `ab.partitions.publicKeyFile = "${fixture.testSignKey}/pubring.pgp"`,
staging подписан приватным ключом фикстуры.

**Assertions:** как AU-A1 (slot B записан, .efi на месте) + журнал verify
(`journalctl -u systemd-sysupdate | grep -i verify` — no reject).

### 4.10. AU-A5 — conflict: CI staged + timer pull (одна версия, один слот)

**ID:** AU-A5. **Цель:** CI уже заstage'ил v2 и сигналил; параллельный прогон
таймера на remote-таргете не ломает состояние: sysupdate идемпотентен, слот B
один, версия одна.
**Тип:** runNixOSTest (та же VM, что AU-A1). **KVM:** ✅. **Приоритет:** P2.

**Действие:** после AU-A1 (v2 в слоте B) — повторный
`systemctl start nixtache-auto-update.service` при неизменном staging.

**Assertions:**
- `singleNewVersion`: ровно одна `nix-store_2` метка; `nix-store_1` (rollback)
  на месте (vacuum ленивый, как в A1 §1а.1).
- `exitZero`: прогон завершился успешно.

---

## 5. Coverage matrix (каждая опция §4 спеки 09 → тест)

| Опция | Тип/default | Покрытие |
|---|---|---|
| `enable` | bool false | AU-1 (off: no units), AU-2 (on: units) |
| `method` | enum `"auto"` | AU-8/9/10 (derive), AU-11 (explicit), AU-22 (A8) |
| `dates` | str `"daily"` | AU-2 (default), AU-3 (override) |
| `randomizedDelaySec` | str `"1h"` | AU-2, AU-3 |
| `persistent` | bool true | AU-2, AU-3 |
| `flake.url` | nullOr str null | AU-4 (wiring), AU-17 (A3) |
| `flake.ref` | nullOr str null | AU-4 (`?ref=`), AU-6 (null) |
| `flake.configuration` | nullOr str null | AU-4 (override), AU-5 (hostName) |
| `flake.flags` | listOf str | AU-4 |
| `flake.sshPrivateKeyFile` | nullOr path null | AU-7 (оба значения) |
| `rebootPolicy` | enum `"never"` | AU-8 (never), AU-12 (if-needed оба пути), AU-13 (window), AU-20 (A6) |
| `rebootWindow.start/end` | str | AU-13, AU-19 (A5) |
| `ab.poll` | bool (derived) | AU-14 (derive+override), AU-A1 (poll в рантайме), AU-A3 (no-poll) |
| — assert A1 | — | AU-15 |
| — assert A2 | — | AU-16 |
| — assert A4 | — | AU-18 |
| — assert A7 | — | AU-21 (📋 partial — warn-контракт) |
| — precedence §8 | — | AU-23/24/25 (eval), AU-F2/F3 (runtime), AU-A5 |
| — observability §11 | — | AU-2 (timer), AU-13 (reboot timer), AU-F1/AU-A1 (журнальные маркеры) |

GAP'ов нет: каждая опция имеет ≥1 теста (правило репо). AU-21 — единственный
partial (warnings не экспонируются nix eval; поведение — `lib.warn`, фиксируется
как контракт, верифицируется глазами при прогоне отчёта).

---

## 6. Новые файлы и проводка в flake.nix

```nix
checks = forAllSystems (system: {
  # pure-eval (быстро, в каждый nix flake check):
  auto-update        = import ./tests/auto-update.nix        { inherit nixpkgs self system; };  # AU-1..AU-25
  # runNixOSTest (KVM, requiredSystemFeatures внутри):
  auto-update-flake-vm = import ./tests/auto-update-flake-vm.nix { inherit nixpkgs self system; };  # AU-F1..F5
  auto-update-ab-vm    = import ./tests/auto-update-ab-vm.nix    { inherit nixpkgs self system; };  # AU-A1..A5
});
```

> KVM-маркировка и группировка — по §9 TEST-SPECS.md: pure-eval в лёгкий
> `auto-update.nix`, runtime — в `*-vm.nix` с `requiredSystemFeatures=["kvm"]`.

---

## 7. Приоритеты

| Приоритет | Кейсы | Примечание |
|---|---|---|
| **P0** | AU-1, AU-2, AU-4, AU-8, AU-9, AU-23, **AU-F1**, **AU-A1** | ядро контракта: оба пути + apply-unit-активация + CI-skip |
| **P1** | AU-3, AU-5, AU-7, AU-10, AU-11, AU-12, AU-13, AU-14, AU-15–AU-20, AU-22, AU-24, AU-F2, AU-F3, AU-F4, AU-A2 | опции + derive + assert-матрица + идемпотентность/rollback |
| **P2** | AU-6, AU-21, AU-25, AU-F5, AU-A3, AU-A4, AU-A5 | edge: ref-suffix, warn-контракт, atomic-write, reboot-reboot, gating no-op, signed pull, conflict |

---

## 8. Чек-лист для реализующего агента

- [ ] `modules/auto-update/default.nix` создан; импорт в `flake.nix`
      `nixosModules.auto-update` (standalone, БЕЗ runner/deploy-target imports).
- [ ] Каждый `mkOption` с `description` (docs CI strict).
- [ ] Все обращения к соседним модулям — `builtins.hasAttr`/`or`-guard'ы
      (AU-16 проверяет: A2 — assertion, не `attribute missing`).
- [ ] Каждый `tests/*.nix` подключён в `flake.nix` `checks.<system>`.
- [ ] Тяжёлые тесты — `requiredSystemFeatures = [ "kvm" ]`.
- [ ] Assert-сценарии через `builtins.tryEval (...).config.system.build.toplevel.outPath`.
- [ ] VM-фикстуры: bare-repo flake + `ab-fixture.nix` — не дублировать
      keypair/nginx-генерацию.
- [ ] `nix flake check --show-trace --all-systems` зелёный; отчёт
      `auto-update` печатает все `ok`.
- [ ] Coverage matrix §5 — каждая опция покрыта.

---

## 9. Open questions (зафиксировать у автора спеки до/при реализации)

1. **AU-F5 (kernel-change reboot):** честная смена ядра в VM дорога; допустим
   ли 📋 partial (pure-eval AU-12A + manual) или требуется полный runtime-кейс
   с двумя kernelPackages в фикстуре?
2. **AU-21 (A7 warning):** nix не экспонирует `lib.warn` через eval API —
   оставить как 📋 partial (документированный контракт) достаточно?
3. **Детект «installed» на ab-пути** (§6.1 спеки 09, шаг 3): парсинг
   `journalctl -u systemd-sysupdate --since <t0>` по строке `Successfully
   installed` — хрупкий к локализации/версии systemd. Альтернатива —
   `systemd-sysupdate list --json=short` до/после и сравнение. Выбрать при
   реализации, зафиксировать в AU-A1.

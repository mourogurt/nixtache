# TEST-SPECS — детальные тест-спеки по 06-ab-image.md и 08-ab-provisioning.md

> **Назначение:** взять высокоуровневые таблицы тестов из `06-ab-image.md`
> (§«Артефакты → тесты») и `08-ab-provisioning.md` (§«Полный план тестов»,
> §«Тесты для runner store overlay») и раскрыть каждый кейс до реализуемого
> уровня: точные Nix-опции, точные assertions, тип теста, нужен ли KVM,
> зависимости. Другой агент реализует по этой спеке реальные файлы в `tests/`.
>
> **Скоуп:** ВСЕ категории тестов из 06 + 08: deploy-пайплайн сценарии A/B/C
> (§1а — Remote deploy / Self-deploy / Signature verification), spec-06
> versioned-stage, Provisioning (P/S/PR), Compression (K), Runner+A/B (R),
> overlay-nix (O), nixos-anywhere (N), runner-store-overlay (RO).
>
> **Подход — conformance / исполняемая спека.** Тесты ниже — это **контракт**,
> который модули nixtache обязаны удовлетворять. Другой агент реализует модули
> (`ab-provision.nix`, `overlay-nix`, `store.mode`, …) так, чтобы тесты
> загорелись зелёным. Маркер 🆕/🔧 поэтому значит НЕ «тест впрок, который
> падает», а «этот тест фиксирует поведение модуля, которого ещё нет в коде —
> реализующему агенту создать модуль/опцию под этот контракт». Каждый кейс
> прописан до уровня точных Nix-значений и assertions, чтобы реализация была
> однозначной.
>
> **Дата:** 2026-08-08. Сверено с исходниками модулей на момент написания.

---

## 0. Конвенции

### 0.1. Статус целевого модуля (для каждого теста)

| Маркер | Значение |
|---|---|
| ✅ **EXISTING** | Модуль/опция уже реализованы в nixtache — тест проверяет текущий код (регрессия). |
| 🆕 **NEW MODULE (contract)** | Модуля ещё нет в `modules/`. Тест — это **conformance-контракт**: определяет точное поведение, которое реализующий агент должен воспроизвести в новом файле (путь указан в секции). До реализации модуля тест ожидаемо красный; цель имплементации — сделать его зелёным. |
| 🔧 **NEW OPTION (contract)** | Модуль есть, но опция новая. Тест фиксирует контракт на новое поведение в существующем модуле — агент добавляет `mkOption` + `config` под этот контракт. |
| 📋 **DOCS/MANUAL** | Автоматизация в runNixOSTest неразумно дорогая/хрупкая; остаётся ручным integration-тестом или runbook'ом (spec 08 сама отмечает такие как «may stay manual»). |

### 0.2. Типы тестов (соответствуют существующим `tests/*.nix`)

| Тип | Каркас | KVM? | Где образец | Применение |
|---|---|---|---|---|
| **pure-eval** | `pkgs.runCommand` + `nixpkgs.lib.nixosSystem` | ❌ нет | `tests/ab-image.nix`, `tests/deploy-target.nix`, `tests/runner.nix` | wiring-проверки: `config.*` существует/равен, polkit-текст, tmpfiles, asserts через `builtins.tryEval`. Быстро. |
| **runNixOSTest** | `pkgs.testers.runNixOSTest` (Python testScript) | ✅ да | `tests/ab-deploy.nix`, `tests/ab-ota-e2e.nix` | реальное поведение в VM: сервис стартует, sysupdate пишет партицию, polkit авторизует. |
| **pexpect-QEMU** | `pkgs.writers.writePython3Bin` + `pkgs.runCommand { requiredSystemFeatures=["kvm"]; }` | ✅ да | `tests/ab-vm.nix` | boot реального A/B-образа в QEMU через serial-консоль; для тестов, где важен ПОЛНЫЙ boot appliance (squashFS mount, boot-complete). |
| **build-compare** | `pkgs.runCommand`, `nix build` нескольких образов, `stat -c%s` | ❌ нет | (новый) | компрессия: сравнение размеров образов. |

> **KVM-маркер:** тяжёлые тесты (runNixOSTest/pexpect) обязаны иметь
> `requiredSystemFeatures = [ "kvm" ]` (как `ab-vm.nix`), иначе они ломают
> рутинный `nix flake check` на runner'е в nspawn без KVM.

### 0.3. Каркас pure-eval сценария (канон из существующих тестов)

Каждый pure-eval тест следует шаблону: `mkHost` (собирает `nixosSystem` с
`self.nixosModules.<x>` + `baseModule` + extra), набор `checks` (bool each),
агрегация в `scenarios`, финальный `pkgs.runCommand` печатает отчёт и
`exit 1` при любом FAIL. **Assert-сценарии** оборачивают
`builtins.tryEval (...).config.system.build.toplevel.outPath` и проверяют
`!result.success` (как `scenarioAutoOffAssert` в `deploy-target.nix`).

### 0.4. Фикстуры (переиспользовать, не дублировать)

- **`tests/ab-fixture.nix`** — `testSignKey` (GPG keypair), `testDeployKey`
  (SSH keypair), `mkAppliance { version, signVerify, dataPartition,
  stagingPath, deployKeyPub, storeSize }` (тонкий consumer поверх реальных
  `deploy-target` + `ab-image` модулей). **ИСПОЛЬЗОВАТЬ ЕГО** для всех VM-тестов
  с appliance.
- **`tests/ab-vm.nix`** содержит локальный `testSignKey` — при расширении
  предпочтительно вынести в общий fixture (см. review §11.2).

### 0.5. Где живут тесты и как подключаются

Новые тест-файлы — в `tests/`; каждый **обязательно** подключается в
`flake.nix` → `checks.<system>.<name> = import ./tests/<name>.nix { ... }`.
Иначе тест не запустится (правило из `AGENTS.md` nixtache).

---

## 1. Тесты spec 06 (A/B image — build + runtime + staging)

> Спека 06 упоминает тесты в §«Артефакты» (строка 272–275): `ab.enable →
> staging/nginx wired; ab.gating → gating-unit wired; assert требует sysupdate
> + bootCounting; versioned-stage — две версии одной cfg не конфликтуют`.
> Первые три **уже реализованы** (см. §1.1). Не покрыто — **versioned-stage**
> (конкурентность + retain-GC) и несколько edge-поведений `runner.deploy.ab`.

### 1.0. Уже покрыто (НЕ дублировать) — реестр существующих проверок

| Опция/поведение | Где протестировано | Файл |
|---|---|---|
| `ab-image`: fixed-mode sizing, max-disk sizing, publicKey→Verify | `checks.ab-image` | `tests/ab-image.nix` (3 сценария) |
| `deploy-target.ab.enable`→polkit (sysupdate+ab-apply, start-only) | `scenarioAb` | `tests/deploy-target.nix` |
| `deploy-target.ab.gating`→path+service+script (forgejoPort, idle-poll, LoadCredential) | `scenarioAbGating` | `tests/deploy-target.nix` |
| `ab.enable` без `systemd.sysupdate`→assert | `scenarioAbAssertNoSysupdate` | `tests/deploy-target.nix` |
| `ab.gating` без `forgejoApiTokenFile`→assert | `scenarioAbGatingAssertNoToken` | `tests/deploy-target.nix` |
| `runner.deploy.ab.enable`→staging bind-mount, nginx autoindex, envs, gc, gnupg, LoadCredential | `scenarioAbStage` | `tests/runner.nix` |
| `runner.forgejoPort` default из forgejoUrl | `scenarioForgejoPort` | `tests/runner.nix` |
| `stagingPath` basename ≠ `nginx.location` basename→assert | `scenarioAbBasenameAssert` | `tests/runner.nix` |
| real action.yml → stage → sign → SSH → sysupdate пишет GPT-партицию | `ab-ota-e2e` | `tests/ab-ota-e2e.nix` |
| real runner module nginx serves ab-stage + signing key | `ab-deploy` | `tests/ab-deploy.nix` |

### 1.1. V1 — `versioned-stage-no-conflict` (pure-eval + retain-GC)

**ID:** `06-V1`
**Цель:** пер-cfg versioned-файлы иммутабельны; retain-GC удаляет только старые
версии, не трогая чужие cfg и не ломая manifest младше retain. (spec 06 §«Создание
staging-dir + конкурентность», строки 88–96; «Артефакты» строка 274.)
**Статус модуля:** ✅ EXISTING (`modules/runner/ab.nix` → `nixtache-ab-gc`
service). Сам GC-скрипт — `script` сервиса; тест проверяет его текст + поведение
через эмуляцию.
**Тип:** pure-eval (инспекция script) + опционально runNixOSTest (реальный прогон
GC на фейковом staging-dir).
**KVM:** опционально (для runtime-варианта).
**Приоритет:** P1.

**Setup (pure-eval):** `mkHost "/srv"` с `services.nixtache.runner.deploy.ab =
{ enable=true; runnerHost="x"; retain=2; }`. Достать `gcScript =
host.config.systemd.services."nixtache-ab-gc".script`.

**Assertions (pure-eval, на текст `gcScript`):**
- `retainInScript`: `lib.hasInfix "retain=2" gcScript` (параметр пробрасывается).
- `sortsVersionDesc`: `lib.hasInfix "sort -rn" gcScript` (GC берёт старшие версии).
- `keepsNewest`: `lib.hasInfix "NR>" gcScript` ( awk-фильтр «оставить N новых»).
- `regeneratesSums`: `lib.hasInfix "sha256sum" gcScript && lib.hasInfix
  "SHA256SUMS" gcScript` (manifest перегенерируется из выживших).
- `removesBothArtifacts`: `lib.hasInfix ".nix-store.raw" gcScript &&
  lib.hasInfix ".efi" gcScript` (старая версия удаляется вместе raw+efi).
- `emptyDirCleanup`: `lib.hasInfix 'rm -f "$cfgdir/SHA256SUMS" "$cfgdir/SHA256SUMS.gpg"' gcScript`.

**Setup (runNixOSTest, опционально для реального прогона):** 1 VM с
`services.nixtache.runner.deploy.ab.enable=true` (container off). В тесте:
создать `/var/lib/nixtache/ab-stage/cfg1/` с `abtest_{1,2,3}.nix-store.raw` +
`.efi` + `SHA256SUMS`; запустить `systemctl start nixtache-ab-gc`; проверить что
`abtest_3` остался, `abtest_1` удалён, `SHA256SUMS` перегенерирован.

**Assertions (runNixOSTest):**
- `keptNewest`: `test -f /var/lib/nixtache/ab-stage/cfg1/abtest_3.nix-store.raw`.
- `removedOld`: `! test -e /var/lib/nixtache/ab-stage/cfg1/abtest_1.nix-store.raw`.
- `sumsRegenerated`: `grep -q abtest_3 /var/lib/nixtache/ab-stage/cfg1/SHA256SUMS`.

> ⚠️ **GAP (см. review §11.1):** текущий GC удаляет `.gpg`, но не пересоздаёт
> подпись. Если target имеет `Transfer.Verify=yes`, после GC manifest unsigned →
> sysupdate на target'е упадёт. Тест должен это поймать: assertion
> `gpgRemovedNotResigned` — после GC файла `.gpg` нет (_known gap_, отметить как
> expected-fail или зафиксировать требуемое поведение).

### 1.2. V2 — `ab-cache-dependency-assert` (pure-eval)

**ID:** `06-V2`
**Цель:** `runner.deploy.ab.enable=true` требует `runner.cache.enable=true`
(assert в `modules/runner/ab.nix` строка 127). spec 06 §«Runner-модуль» строка 151.
**Статус модуля:** ✅ EXISTING.
**Тип:** pure-eval (`builtins.tryEval`).
**Приоритет:** P1.

**Setup:** `mkHost "/srv"` с `services.nixtache.runner.deploy.ab = { enable=true;
runnerHost="x"; }` и **`cache.enable=false`** (или не выставлено — но тогда
default `cache` может требовать domain; см. примечание).

**Assertions:**
- `refused`: `!tryEval(...).success` — eval отказывает.
- (опц.) `messageMentionsCache`: сообщение assert содержит `cache.enable` —
  проверить через `host.config.assertions` (найти элемент с `assertion ==
  runnerCfg.cache.enable`, проверить `message`).

### 1.3. V3 — `ab-runnerHost-required-assert` (pure-eval)

**ID:** `06-V3`
**Цель:** `runner.deploy.ab.runnerHost != ""` (assert строка 135). Если
`enable=true`, но `runnerHost` пустой/не задан → eval отказывает.
**Статус модуля:** ✅ EXISTING.
**Тип:** pure-eval.
**Приоритет:** P2.

**Setup:** `mkHost "/srv"` с `deploy.ab = { enable=true; }` и **`runnerHost =
lib.mkForce ""`**, плюс валидный `cache` (чтобы изолировать именно этот assert).

**Assertions:** `refused = !tryEval(...).success`.

### 1.4. V4 — `ab-forceAfterTimeout-script-branch` (pure-eval)

**ID:** `06-V4`
**Цель:** `deploy-target.ab.forceAfterTimeout` меняет ветку gating-скрипта.
spec 06 §«gating-unit» строки 217–221. Текущий `scenarioAbGating` (`deploy-target.nix`)
не покрывает `forceAfterTimeout=true`.
**Статус модуля:** ✅ EXISTING.
**Тип:** pure-eval.
**Приоритет:** P2.

**Setup:** `mkHostAb` (с runner-модулем для `forgejoPort`) + `deploy-target.ab =
{ enable=true; gating=true; forgejoApiTokenFile=/dev/null; forceAfterTimeout=true;
idleWaitTimeout=600; }` + `systemd.sysupdate.enable=true` + `bootCounting`.

**Assertions (на `abApplyScript`):**
- `forceFlagOne`: `lib.hasInfix '"1"' abApplyScript` (force=1 в скрипте при `=true`).
- `forceBranchText`: `lib.hasInfix "forceAfterTimeout=true" abApplyScript`
  (сообщение ветки принудительного применения).
- Контр-сценарий (`forceAfterTimeout=false`, уже есть в `scenarioAbGating`):
  `lib.hasInfix "forceAfterTimeout=false"`.

---

## 1а. Deploy pipeline e2e — сценарии A/B/C (spec 08 §«Полный план тестов»)

> Сценарии полного деплой-пайплайна: **A** — remote (deployer → target по SSH,
> partition target), **B** — self-deploy (одна машина, `file://`, local
> trigger), **C** — signature verification (reject wrong/tampered/unsigned).
> Все VM-тесты используют **provision-модуль** для раскладки A/B слотов
> (`services.nixtache.deploy-target.ab.partitions`, см. §2) — ручные
> `ab-disk-init` oneshot'ы в тестах запрещены: слоты создаёт
> `nixtache-ab-provision.service`, transfers (Target-сторона) дерируются
> модулем; тест переопределяет только placeholder `Source` (он `mkDefault`).

### 1а.1. A1 — `ab-ota-e2e` ✅ РЕАЛИЗОВАН (`tests/ab-ota-e2e.nix`)

**ID:** `08-A1`
**Цель:** полный pipeline через реальный `action.yml` на реальный GPT-диск:
stage → GPG-sign → SSH trigger → sysupdate пишет v2 в партицию.
**Статус:** ✅ green на KVM. Target-нода переведена на provision-модуль
(2026-08-09): `ab-disk-init` удалён.
**Тип:** runNixOSTest (2 ноды: deployer + target). **KVM:** ✅.

**Setup (target, ключевое):**

```nix
imports = [ self.nixosModules.deploy-target ];
virtualisation.emptyDiskImages = [ 2048 ];          # /dev/vdb
services.nixtache.deploy-target = {
  enable = true;
  ab.enable = true;
  ab.gating = false;
  ab.partitions = {                                 # ← provision-модуль владеет ВСЕМ sysupdate
    enable = true;
    slotSize = "512M";
    autoInit = true;
    imageId = "abtest";
    source = "http://deployer/ab-stage/abtest-remote";  # remote → url-file
    bootTarget = "/var/lib/nixtache/ab-slots/";         # на VM нет ESP
    slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
    slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
  };
  deployUser = { name = "nixos-deploy"; authorizedKey = fixture.deployKeyPub; autoProvision = true; };
};
# НИКАКОГО ручного `systemd.sysupdate = {...}`: модуль включает sysupdate
# (mkDefault true) и дерирует ОБА transfer'а (nix-store + UKI).
```

Версии: **v1 = NixOS без hello** (`fixture.mkAppliance { version="1"; … }`),
**v2 = NixOS С hello** (`extraPackages = [ pkgs.hello ]`). Декларативные
"1"/"2" в фикстуре — осознанная детерминированность теста (fake-nix
перехватывает `nix build`, поэтому prebuilt-пакет сохраняет имена
`abtest_2.*`). В проде версия назначается CI в рантайме: action.yml пишет
calver в repo-файл `image-version` перед `nix build`, модуль читает его
через `ab-image.imageVersionFile` (pure-eval покрытие — `tests/ab-image.nix`,
сценарий imageVersionFile). v1 store raw dd'ится в слот A до деплоя — слот A
содержит реальную «текущую» систему, а не пустую партицию с версионной
меткой.

Deployer-нода: extracted `action.yml` run-скрипт + fake-nix (`flake show` /
`build` stub'ы), nginx отдаёт staging по HTTP, credentials через
/run/credentials — без изменений (см. файл).

**Assertions:**
- `target.wait_for_unit("nixtache-ab-provision.service")` — GPT размечен
  **модулем**: `sgdisk -p /dev/vdb | grep nix-store_1` + `grep _empty`.
- `dd if=<v1 raw> of=/dev/vdb1` → `unsquashfs -l /dev/vdb1 | grep -c hello` == 0
  (v1 — baseline без hello).
- После прогона action.yml: **runtime version** — в логе
  `artifacts/deploy_abtest-remote.log` есть `assigning runtime version
  <14 цифр>` и `/tmp/image-version` содержит ту же calver-версию (в бою она
  попадёт в сборку через imageVersionFile; здесь build подменён fake-nix).
  Затем `wait_until_succeeds("test -f
  /var/lib/nixtache/ab-slots/abtest_2.efi")` → `sgdisk -p /dev/vdb | grep
  nix-store_2` (sysupdate записал `_empty` → переименовал в `nix-store_2`).
- **Content proof:** `unsquashfs -l /dev/vdb2 | grep hello` (v2 доставил
  НОВЫЙ контент), `unsquashfs -l /dev/vdb1 | grep -c hello` == 0 и
  `nix-store_1` на месте (rollback-слот не тронут — vacuum ленивый).

### 1а.2. A2–A5 — варианты A1 (compression / slotSize) 🆕

**Тип:** runNixOSTest/pexpect-QEMU. **KVM:** ✅. **Приоритет:** P2.

| # | Test name | Отличие от A1 | Доп. assertion |
|---|---|---|---|
| A2 | `ab-ota-e2e-squashfs` | v2 package: `storeFs="squashfs" storeCompression="zstd" storeCompressionLevel=19` | после записи: `file -s /dev/vdb2 \| grep -i squashfs` (без reboot — по сигнатуре слота) |
| A3 | `ab-ota-e2e-erofs` | `storeFs="erofs"` + zstd-19 | `file -s /dev/vdb2 \| grep -i erofs` |
| A4 | `ab-ota-e2e-nocompress` | `storeCompression=null` | размер записанного слота ≈ некомпримированному (`du -B1` staged raw ≈ slotSize content) |
| A5 | `ab-ota-e2e-percent-slot` | `ab.partitions.slotSize="25%"` (резолвится provision'ом от /dev/vdb) | `lsblk -bno SIZE /dev/vdb1` ≈ 25% диска ±2% |

**Setup:** как A1; v2 appliance собирается `fixture.mkAppliance` с
соответствующими `storeFs/storeCompression/storeCompressionLevel/storeSize`.
Для A5: `slotSize` в `ab.partitions` = `"25%"`, `ab-image.storeSize` — любой
абсолютный, покрывающий контент (assert A2 скипается для `%`).
**Общее:** boot в новый слот НЕ требуется — проверка по GPT label + сигнатуре
ФС в записанной партиции (reboot-вариант покрывают K4/AB-swap тесты).

### 1а.3. B1 — `ab-deploy-self` 🆕

**ID:** `08-B1`
**Цель:** self-deploy без SSH: staging локальный (`file://`), trigger —
локальный `systemctl start systemd-sysupdate.service` (эквивалент
local-self ветки action.yml без gating).
**Статус:** 🆕. **Тип:** runNixOSTest (1 нода). **KVM:** ✅. **Приоритет:** P1.

**Setup:** 1 VM = target из A1 (provision-модуль, /dev/vdb, autoInit), но
`ab.partitions.source = "/var/lib/nixtache/ab-stage/abtest"` — **local** deploy:
модуль сам выводит `file://` + `regular-file` для ОБОИХ transfers (nix-store +
UKI). Ручных `systemd.sysupdate.transfers` нет.
- v2 sysupdate-package: `system.extraDependencies = [ v2SysupdatePkg ]`; в
  testScript — `cp ${v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/`
  (SHA256SUMS уже в пакете; Verify=no — подпись не нужна).

**Assertions:**
- provision разметил слоты (как A1).
- `target.succeed("systemctl start systemd-sysupdate.service")` →
  `sgdisk -p /dev/vdb | grep nix-store_2`; `abtest_2.efi` в
  `/var/lib/nixtache/ab-slots/`.
- Журнал: `journalctl -u systemd-sysupdate | grep "Successfully installed"`.

### 1а.4. B2 — `ab-deploy-self-gating` (idle → apply) 🆕

**ID:** `08-B2`
**Цель:** gating-unit (`nixtache-ab-apply.{path,service}`): `ab-pending`
появился → runners idle → sysupdate запускается.
**Статус:** 🆕. **Тип:** runNixOSTest (1 нода). **KVM:** ✅. **Приоритет:** P1.

**Setup:** B1 + `ab.gating = true`, `ab.forgejoApiTokenFile = pkgs.writeText
"tok" "test-token"`, `ab.idleWaitTimeout = 60`. Mock Forgejo API —
`services.nginx` на `localhost:<port>` отдаёт на
`/api/v1/actions/runners` статический JSON `[]` (все idle).
> **Внимание (gap):** gating-скрипт читает порт из
> `config.services.nixtache.runner.forgejoPort` — опции runner-модуля. В тесте
> без runner-модуля: объявить stub `options.services.nixtache.runner.forgejoPort
> = mkOption { type = types.port; default = <mock-port>; };` в node-модуле
> (реализующему агенту — либо так, либо вынести `forgejoPort` в deploy-target;
> зафиксировать выбор в §11 при реализации).

**Действие:** `touch /var/lib/nixtache/ab-pending && systemctl start
nixtache-ab-apply.service` (ровно то, что делает local-self ветка action.yml).

**Assertions:**
- `wait_until_succeeds("sgdisk -p /dev/vdb | grep nix-store_2")` — apply
  дождался idle и триггернул sysupdate.
- `test ! -f /var/lib/nixtache/ab-pending` — pending снят после apply.
- Журнал: `journalctl -u nixtache-ab-apply | grep "runners idle"`.

### 1а.5. B3 — `ab-deploy-self-busy` (busy → отложено) 🆕

**ID:** `08-B3`
**Цель:** gating при занятых runners: mock возвращает busy → по таймауту
образ остаётся pending, sysupdate НЕ запускается.
**Статус:** 🆕. **Тип:** runNixOSTest. **KVM:** ✅. **Приоритет:** P2.

**Setup:** как B2, но mock отдаёт `[{"name":"r1","busy":true}]`;
`idleWaitTimeout = 20` (короткий, чтобы тест был быстрым; poll sleep 10s);
`forceAfterTimeout = false`.

**Assertions:**
- `target.wait_for_unit("nixtache-ab-apply.service")` (oneshot завершился).
- `test -f /var/lib/nixtache/ab-pending` — pending НЕ снят.
- `sgdisk -p /dev/vdb | grep -c nix-store_2` == 0 — sysupdate не писал слот B.
- Журнал: `grep "still busy.*forceAfterTimeout=false"`.

### 1а.6. B4 — `ab-deploy-self-busy-timeout` (busy + force → apply) 🆕

**ID:** `08-B4`
**Цель:** busy + `forceAfterTimeout = true` → по таймауту sysupdate
запускается принудительно.
**Статус:** 🆕. **Тип:** runNixOSTest. **KVM:** ✅. **Приоритет:** P2.

**Setup:** как B3, но `forceAfterTimeout = true`.

**Assertions:**
- `wait_until_succeeds("sgdisk -p /dev/vdb | grep nix-store_2")`.
- `test ! -f /var/lib/nixtache/ab-pending`.
- Журнал: `grep "applying anyway"`.

### 1а.7. C1–C4 — signature verification (Verify=yes) 🆕

**ID:** `08-C1..C4`
**Цель:** sysupdate отвергает неправильно подписанный/искажённый/неподписанный
образ и принимает корректный (positive control).
**Статус:** 🆕. **Тип:** runNixOSTest (2 ноды, как A1). **KVM:** ✅.
**Приоритет:** C1/C2 — P0, C3/C4 — P2.

**Общий setup (отличия от A1):**
- Target: `ab.partitions.publicKeyFile = "${fixture.testSignKey}/pubring.pgp"`
  — модуль ставит pubring (`/etc/systemd/import-pubring.pgp` + /usr/lib
  symlink) и сам включает `Transfer.Verify=yes` (заданный ключ ⇒ verify,
  как в ab-image). Deployer подписывает ПРИВАТНЫМ ключом
  (`fixture.testSignKey/priv.asc`), target проверяет публичным.
- Deployer: staging формируется как в A1 (реальный action.yml знакит
  `SHA256SUMS` → `SHA256SUMS.gpg` через `fixture.testSignKey`).

| # | Test name | Мутация staging | Assertion |
|---|---|---|---|
| C1 | `ab-deploy-verify-wrong-key` | подпись ДРУГИМ gpg-ключом (сгенерировать второй throwaway keypair по образцу `fixture.testSignKey`) | sysupdate падает: `journalctl -u systemd-sysupdate \| grep -iE "verify\|signature"`; `grep -c nix-store_2` == 0 |
| C2 | `ab-deploy-verify-tampered` | после подписи: `printf 'x' \| dd of=abtest_2.nix-store.raw bs=1 seek=1024 conv=notrunc` (hash mismatch) | как C1 — отвергнут, слот не записан |
| C3 | `ab-deploy-verify-unsigned` | удалить `SHA256SUMS.gpg` из staging | как C1 — unsigned rejected |
| C4 | `ab-deploy-verify-correct` | без мутации (positive control) | `nix-store_2` появился; `abtest_2.efi` записан |

**Действие (все C):** на target — `systemctl start
systemd-sysupdate.service` напрямую (без action.yml: пайплайн подписи уже
покрыт A1; здесь тестируется верификация на стороне target'а). Для C1–C3
ожидается failure: `target.fail("systemctl start systemd-sysupdate.service")`
или успех-но-не-записал (зависит от режима reject'а — зафиксировать по факту,
ключевой assertion: **слот B не записан**).

> **Примечание:** C4 — обязательный positive control: без него C1–C3 могли бы
> «проходить» из-за сломанного staging в целом (false negative).

---

## 2. Provisioning (spec 08 §1–§4) — модуль `ab-provision`

> **Контракт на новый модуль.** Целевого модуля
> `services.nixtache.deploy-target.ab.partitions.*` ещё нет — тесты в этой секции
> **определяют его контракт** (исполняемая спека). Реализующему агенту: создать
> файл `modules/deploy-target/ab-provision.nix` с опциями из §2.1, подключить в
> `modules/deploy-target/default.nix` (`imports += [ ./ab-provision.nix ]`), и
> добиться прохождения всех P/S/PR-тестов. Маркер кейсов — 🆕 NEW MODULE (contract).

### 2.1. Опции модуля (спека 08 §4 — реализующему агенту)

```nix
services.nixtache.deploy-target.ab.partitions = {
  enable          = mkOption types.bool default false;
  slot_a          = submodule { type, storage, label };   # type: "partition"|"regular-file"
  slot_b          = submodule { type, storage, label };   #storage: "auto"|"/dev/..."|dir
  slotSize        = mkOption types.str;                    # "2G" | "512M" | "10%"
  autoInit        = mkOption types.bool default false;
  onSizeMismatch  = mkOption types.enum ["error" "wipe"] default "error";
  protectedLabels = mkOption (types.listOf types.str) default ["root" "esp" "boot"];
  # mountPoint убран (review §11.6 — избыточна; монтирование знает ab-image)
};
```

### 2.2. P1 — `ab-provision-init` (runNixOSTest)

**ID:** `08-P1`
**Цель:** пустой диск + `autoInit=true` → provision создаёт два слота (sgdisk).
spec 08 §2 строки 282–289, §«Сценарии миграции» B.
**Статус модуля:** 🆕 NEW MODULE (`ab-provision.nix` + provision script).
**Тип:** runNixOSTest.
**KVM:** ✅ да.
**Приоритет:** P1.

**Setup (target node):**
```nix
virtualisation.emptyDiskImages = [ 4096 ];     # /dev/vdb, 4 GB
services.nixtache.deploy-target.ab.partitions = {
  enable = true;
  autoInit = true;
  slotSize = "512M";
  slot_a = { type = "partition"; storage = "/dev/vdb"; label = "nix-store_1"; };
  slot_b = { type = "partition"; storage = "/dev/vdb"; label = "_empty"; };
};
systemd.sysupdate.enable = true;
boot.loader.systemd-boot.bootCounting.enable = true;
```

**Assertions (testScript):** после `target.wait_for_unit("nixtache-ab-provision.service")`:
- `slotACreated`: `target.succeed("sgdisk -p /dev/vdb | grep nix-store_1")`.
- `slotBCreated`: `target.succeed("sgdisk -p /dev/vdb | grep _empty")`.
- `slotASize`: `target.succeed("lsblk -bno SIZE /dev/vdb1 | head -1")` ≈ 512M (допуск ±2%).
- `slotBSize`: то же для `/dev/vdb2`, равно slot A.
- `serviceType`: (pure-eval дополнение) `config.systemd.services."nixtache-ab-provision".serviceConfig.Type == "oneshot"`.
- `beforeSysupdate`: `lib.elem "systemd-sysupdate.service" config.systemd.services."nixtache-ab-provision".before`.

### 2.3. P2 — `ab-provision-idempotent` (runNixOSTest)

**ID:** `08-P2`
**Цель:** слоты уже есть → повторный запуск provision — no-op (партиции не
изменены). spec 08 §2 строки 249–256.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** как P1, но после первого прогона capture `sgdisk -p /dev/vdb` (хэш
таблицы партиций), затем `systemctl restart nixtache-ab-provision`, снова capture.

**Assertions:**
- `partTableUnchanged`: хэш `sgdisk -p` до == после (можно через
  `target.succeed("sgdisk -p /dev/vdb | sha256sum")` до и после).
- `serviceExitClean`: `systemctl is-active nixtache-ab-provision` == `active`
  (RemainAfterExit).

### 2.4. P3 — `ab-provision-second-disk` (runNixOSTest)

**ID:** `08-P3`
**Цель:** `storage = "/dev/vdb"` → слоты на vdb, vda (корневой диск) **не тронут**.
spec 08 §1 сценарий C, §4 пример строка 568.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** 2 empty disks (`virtualisation.emptyDiskImages = [ 4096 4096 ]` →
`/dev/vdb`, `/dev/vdc`). `slot_a.storage = slot_b.storage = "/dev/vdc"`. До
запуска provision — capture GPT vdb.

**Assertions:**
- `slotsOnVdc`: `sgdisk -p /dev/vdc | grep -E 'nix-store_1|_empty'`.
- `vdbUntouched`: GPT `/dev/vdb` до == после (нет новых партиций) — `sgdisk -p
  /dev/vdb` хэш неизменен (диск пустой, должен остаться пустым).

### 2.5. P4 — `ab-provision-different-disks` (pure-eval + runNixOSTest)

**ID:** `08-P4`
**Цель:** `slot_a.storage ≠ slot_b.storage` (true A/B на разных дисках) → модуль
генерирует **ДВА** sysupdate-transfer (InstancesMax=1 каждый), а не один
(InstancesMax=2). spec 08 §4 строки 532–557 (производный конфиг).
**Статус:** 🆕 NEW MODULE.
**Тип:** pure-eval (структура transfers) — достаточно для проверки логики
деривации; опционально runNixOSTest для реальной записи.
**KVM:** нет для pure-eval.
**Приоритет:** P1.

**Setup (pure-eval):** `mkHostAb` с `partitions = { enable=true; slot_a={
type="partition"; storage="/dev/vdb"; label="nix-store_1"; };
slot_b={type="partition"; storage="/dev/vdc"; label="_empty"; }; slotSize="512M"; }`.

**Assertions (pure-eval, на `config.systemd.sysupdate.transfers`):**
- `twoTransfers`: доля transfer'ов с префиксом `10-nix-store` == 2 (имена
  `10-nix-store-a`, `10-nix-store-b`).
- `eachInstancesMax1`: оба transfer'а имеют `Target.InstancesMax == 1`.
- `singleDiskVariant`: в контр-сценарии (storage одинаковый) — **один** transfer
  `10-nix-store` с `InstancesMax == 2`.

### 2.6. P5 — `ab-provision-regular-file-skip` (pure-eval + runNixOSTest)

**ID:** `08-P5`
**Цель:** `type = "regular-file"` → provision-сервис **НЕ** провижинится (нет
sgdisk); sysupdate сам создаёт файлы. spec 08 §2 строки 316–319, §4 строки 583–586.
**Статус:** 🆕 NEW MODULE.
**Тип:** pure-eval.
**KVM:** нет.
**Приоритет:** P1.

**Setup:** `partitions = { enable=true; slot_a={ type="regular-file";
storage="/var/lib/nixtache/ab-slots/"; }; slot_b={ type="regular-file";
storage="/var/lib/nixtache/ab-slots/"; }; }`.

**Assertions (pure-eval):**
- `noProvisionService`: `!(host.config.systemd.services ? "nixtache-ab-provision")`.
- `transferTypeRegularFile`: `config.systemd.sysupdate.transfers."10-nix-store".Target.Type
  == "regular-file"`.

### 2.7. S1 — `ab-provision-size-error` (runNixOSTest)

**ID:** `08-S1`
**Цель:** slotSize в конфиге изменён (4G), actual=2G, `onSizeMismatch="error"` →
provision не пересоздаёт, **отключает sysupdate** (таймер masked/stopped) + пишет
понятное сообщение. spec 08 §3 строки 382–397.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** диск с предсозданными слотами по 512M (`sgdisk --new=...:+512M` в
initrd-service, как `ab-disk-init` в `ab-ota-e2e.nix`); `partitions.slotSize =
"1G"`, `onSizeMismatch = "error"`.

**Assertions:**
- `sysupdateStopped`: `systemctl is-active systemd-sysupdate.service` != `active`
  (или `systemctl is-enabled systemd-sysupdate.timer` показывает masked/disabled).
- `mismatchLogged`: `journalctl -u nixtache-ab-provision` содержит `Size mismatch`
  (или конкретный текст сообщения из §3 строки 385).
- `slotsPreserved`: `sgdisk -p /dev/vdb` — старые партиции на месте (не удалены).

### 2.8. S2 — `ab-provision-size-wipe` (runNixOSTest)

**ID:** `08-S2`
**Цель:** `onSizeMismatch="wipe"` → обе партиции удаляются, пересоздаются с новым
размером и сконфигурированными метками `nix-store_1` + `_empty` (та же пара,
что создаёт autoInit — поэтому отдельное post-wipe состояние не нужно и wipe
идемпотентен). spec 08 §3 строки 399–416.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** как S1, но `onSizeMismatch = "wipe"`. До provision — записать маркер
в slot A (`dd if=/dev/urandom of=/dev/vdb1 bs=1M count=10`).

**Assertions:**
- `slotsRecreated`: `sgdisk -p /dev/vdb` — две партиции нового размера.
- `newSize`: размер партиций ≈ 1G (slotSize).
- `bothLabeledEmpty`: `sgdisk -p /dev/vdb` содержит `nix-store_1` и `_empty` —
  `sgdisk -p | grep nix-store_1` и `sgdisk -p | grep _empty`.
- `oldDataGone`: `dd if=/dev/vdb1 bs=1M count=10 | sha256sum` != исходный (данные
  стёрты).
- `needsDeploySignal`: `test -f /var/lib/nixtache/ab-needs-initial-deploy`
  (spec 08 §3 строка 410).

### 2.9. S3 — `ab-provision-no-space` (runNixOSTest)

**ID:** `08-S3`
**Цель:** `autoInit=true`, но места на диске нет (диск заполнен root-партицией) →
provision падает с понятным сообщением (не молча). spec 08 §1-B строки 170–200.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** `/dev/vdb` 512MB; одна партиция занимает весь диск (`sgdisk --new=1:0:0`
в initrd-service); `partitions.slotSize="2G"`, `autoInit=true`.

**Assertions:**
- `serviceFailed`: `systemctl is-failed nixtache-ab-provision` (или `! is-active`).
- `noSpaceMessage`: `journalctl -u nixtache-ab-provision` содержит `Not enough
  free space` (текст из spec 08 §1-B строка 275) ИЛИ `free space`.
- `messageListsOptions`: сообщение упоминает альтернативы (`nixos-anywhere` /
  `shrink` / `second disk`) — spec 08 строки 191–199.

### 2.10. S4 — `ab-provision-percent-slotSize` (runNixOSTest)

**ID:** `08-S4`
**Цель:** `slotSize = "10%"` → резолвится от размера устройства. spec 08 §4 строки
472–476, §«Asserts» 603–613 (процент skip'ает assert storeSize==slotSize).
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P1.

**Setup:** `/dev/vdb` 2GB; `partitions.slotSize = "10%"`, `autoInit = true`.

**Assertions:**
- `slotSize10pct`: каждая партиция ≈ 200MB (10% от 2GB, допуск ±5%):
  `lsblk -bno SIZE /dev/vdb1` в диапазоне `[190M, 210M]`.
- `assertSkipped`: (pure-eval дополнение) при `slotSize="10%"` eval НЕ падает на
  assert `storeSize==slotSize`, даже если `ab-image.storeSize="2G"`.

### 2.11. PR1 — `ab-provision-protected-label` (runNixOSTest)

**ID:** `08-PR1`
**Цель:** wipe требуется для партиции с `protectedLabel` → **fail** (данные не
тронуты). spec 08 §3 строки 496–500, §4 protectedLabels.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**Приоритет:** P2.

**Setup:** `/dev/vdb` с партицией `data` (label из `protectedLabels`) + слотами
старого размера. `protectedLabels = ["root" "data"]`. Изменить `slotSize` чтобы
триггерить wipe, который перекрывает `data`.

**Assertions:**
- `serviceFailed`: `systemctl is-failed nixtache-ab-provision`.
- `dataUntouched`: marker, записанный в `data`-партицию до provision, survives
  (`dd if=/dev/disk/by-partlabel/data ... | grep MARKER`).
- `protectedMessage`: journal содержит упоминание protected label / отказ wipe.

### 2.12. Provisioning — assert-сценарии (pure-eval)

Группа pure-eval проверок на asserts spec 08 §4 строки 590–624. Все — 🆕 NEW
MODULE, тип pure-eval, `builtins.tryEval`.

| ID | Setup | Assert message содержит |
|---|---|---|
| `08-A1` | `slot_a.type="partition"`, `slot_b.type="regular-file"` | `same Target.Type` (строки 596–599) |
| `08-A2` | `slotSize="2G"`, `ab-image.storeSize="4G"` (оба абсолютные) | `storeSize` / `slotSize` / `Must match` (605–612) |
| `08-A3` | `autoInit=true`, `slot_a.type="regular-file"` | `autoInit = true requires type = "partition"` (616–618) |
| `08-A4` | `slot_a.type="partition"`, `slot_a.storage="/srv/foo"` (не /dev и не auto) | `partition type requires storage` (621–623) |
| `08-A5` | слотов нет, `autoInit=false` | сообщение про `autoInit` или «слотов нет» (§2 строки 259–264, 348) |

---

## 3. Compression (spec 08 §5) — существующий модуль `ab-image`

> Опции `storeFs`, `storeCompression`, `storeCompressionLevel` уже реализованы в
> `modules/ab-image/default.nix` (строки 157–202). Тесты ниже — ✅ EXISTING.

### 3.0. Pure-eval дополнение к `tests/ab-image.nix` (быстрая проверка wiring)

Добавить в существующий `checks.ab-image` (новые сценарии):
- `storeFsErofs`: `config.image.repart.partitions.nix-store.repartConfig.Format == "erofs"` при `storeFs="erofs"`.
- `compressionKeyForwarded`: при `storeCompression="zstd"` → `repartConfig.Compression == "zstd"`.
- `compressionLevelForwarded`: при `storeCompressionLevel=19` → `repartConfig.CompressionLevel == 19`.
- `compressionNull`: при `storeCompression=null` → ключа `Compression` **нет** в repartConfig (`!(repartConfig ? Compression)`).

### 3.1. K1 — `ab-compression-squashfs-zstd` (build-compare)

**ID:** `08-K1`
**Цель:** squashFS + zstd-19 → образ **меньше** чем no-compress.
**Статус:** ✅ EXISTING.
**Тип:** build-compare.
**KVM:** ❌ нет.
**Приоритет:** P2.

**Setup:** собрать два `sysupdate-package` через `ab-fixture.nix`-стиль `mkAppliance`
(один `storeCompression=null`, другой `storeCompression="zstd";
storeCompressionLevel=19`), `storeFs="squashfs"`.

**Assertions:**
- `zstdSmaller`: `stat -c%s <zstd-raw> < <stat -c%s <none-raw>` (nix-store.raw).
- `sameVersion`: оба образа одной версии (контроль).

### 3.2. K2 — `ab-compression-erofs-zstd` (build-compare)

**ID:** `08-K2`
**Цель:** EROFS + zstd-19 → меньше чем squashfs+none.
**Статус:** ✅ EXISTING.
**Тип:** build-compare.
**Приоритет:** P2.

**Setup:** 2 образа: `erofs`+`zstd,level=19` vs `squashfs`+`null`.

**Assertions:**
- `erofsSmaller`: `stat -c%s <erofs-raw> < <stat -c%s <squashfs-none-raw>`.

### 3.3. K3 — `ab-compression-levels-monotonic` (build-compare)

**ID:** `08-K3`
**Цель:** zstd-1 vs zstd-9 vs zstd-19 → монотонное уменьшение размера.
**Статус:** ✅ EXISTING.
**Тип:** build-compare.
**приоритет:** P2.

**Setup:** 3 образа: zstd level ∈ {1, 9, 19}, одинаковый `storeFs`.

**Assertions:**
- `monotonicDecrease`: `size(zstd-1) >= size(zstd-9) >= size(zstd-19)` (допуск:
  размеры могут совпасть на маленьком closure; для надёжности использовать
  appliance с большим store — `storePaths` из тяжёлого closure).

### 3.4. K4 — `ab-compression-mount` (pexpect-QEMU)

**ID:** `08-K4`
**Цель:** squashFS и EROFS образы реально **mount'ятся** и `/nix/store` доступен
после boot. spec 08 §5 строки 920–945.
**Статус:** ✅ EXISTING.
**Тип:** pexpect-QEMU (как `ab-vm.nix`).
**KVM:** ✅.
**Приоритет:** P1 (доказательство что компрессия не ломает boot).

**Setup:** 2 `mkAppliance` (squashfs+zstd, erofs+zstd). Для каждого — pexpect-driver
из `ab-vm.nix`.

**Assertions (в driver, после boot):**
- `storeMounted`: `mount | grep /nix/store`.
- `fstypeCorrect`: `mount | grep /nix/store | grep -E 'squashfs|erofs'` (соответствует storeFs).
- `storeReadable`: `ls /nix/store | wc -l` > 0.
- `bootComplete`: `systemctl is-active boot-complete.target` == `active`.

---

## 4. Runner + A/B compatibility (spec 08 §7)

### 4.1. R3 — `ab-runner-assert-native-store` (pure-eval)

**ID:** `08-R3`
**Цель:** `store.path = "/"` + `ab-image.enable = true` → **assertion fires**.
spec 08 §7 строки 1217–1230. **Assert уже реализован** в `modules/runner/store.nix`
строки 78–89.
**Статус:** ✅ EXISTING (нужен только тест-сценарий).
**Тип:** pure-eval.
**приоритет:** P1.

**Setup:** `mkHost "/"` (native store) + импорт `self.nixosModules.ab-image` +
`services.nixtache.ab-image.enable = true`.

**Assertions:**
- `refused`: `!builtins.tryEval(...config.system.build.toplevel.outPath).success`.
- `messageMentions`: найти в `host.config.assertions` элемент с assertion про
  `store.path != "/" || !ab-image.enable`, проверить `message` содержит
  `read-only` и `/srv`.

### 4.2. R1 — `ab-runner-store-clone` (runNixOSTest)

**ID:** `08-R1`
**Цель:** после A/B boot (squashFS /nix/store) — `nix-daemon-storage.service`
клонирует store в `/srv/nix`, `nix-daemon-custom` активен. spec 08 §7 строки
1176–1204.
**Статус:** ✅ EXISTING (runner store machinery + ab-image оба есть).
**Тип:** runNixOSTest.
**KVM:** ✅.
**приоритет:** P1.

**Setup:** 1 VM: `services.nixtache.runner = { enable=true; store.path="/srv";
... }` + `services.nixtache.ab-image.enable=true` (appliance profile). Нужен
полноценный boot — поэтому либо `mkAppliance` с добавленным runner-конфигом, либо
отдельная VM-сборка. **Сложность:** appliance profile форсит `nix.enable=false`,
а runner требует nix — разрешается через relocated store (`/srv/nix`). Тест
проверяет именно эту интеграцию.

**Assertions:**
- `customStorePopulated`: `ls /srv/nix/store/ | wc -l` > 0.
- `customDaemonActive`: `systemctl is-active nix-daemon-custom` == `active`.
- `storageRan`: `systemctl is-active nix-daemon-storage` == `active` (RemainAfterExit).

> ⚠️ **ЗАВИСИМОСТЬ:** этот тест требует, чтобы runner-контейнер стартовал на
> A/B-host. На appliance (`nix.enable=false`) системный nix-daemon может не
> существовать → `nix-daemon-storage.requires=["nix-daemon.service"]` упадёт.
> Реализующему агенту: проверить, что на appliance profile `nix-daemon.service`
> всё же поднимается (или адаптировать requires). См. review §11.3.

### 4.3. R2 — `ab-runner-build` (runNixOSTest)

**ID:** `08-R2`
**Цель:** CI build (`nix build`) работает на A/B-host через relocated store.
**Статус:** ✅ EXISTING.
**Тип:** runNixOSTest (продолжение R1).
**KVM:** ✅.
**приоритет:** P1.

**Setup:** как R1, в testScript после старта — `nix build nixpkgs#hello` (или
`nix build --store ...` через custom daemon socket).

**Assertions:**
- `buildSucceeds`: `nix build` exit 0.
- `outputInSrv`: output path существует в `/srv/nix/store/`.

### 4.4. R4 — `ab-runner-reclone-after-swap` (pexpect-QEMU, сложный)

**ID:** `08-R4`
**Цель:** boot v1 → clone → sysupdate → boot v2 → re-clone добавляет НОВЫЕ v2
пути, старые v1 пути остаются (additive). spec 08 §7 строки 1257–1273.
**Статус:** ✅ EXISTING (но требует 2-boot последовательность).
**Тип:** pexpect-QEMU (multi-reboot).
**KVM:** ✅.
**приоритет:** P2.

**Setup:** собрать v1 и v2 appliance (как `ab-vm.nix` + `ab-ota-e2e.nix`); boot
v1, дождаться clone, выполнить sysupdate до v2, reboot, дождаться второго clone.

**Assertions:**
- `v2PathsVisible`: после второго boot — пути из v2 closure в `/srv/nix/store/`.
- `v1PathsRetained`: пути из v1 closure **тоже** в `/srv/nix/store/` (additive).

> **Сложность:** multi-boot pexpect-тест на A/B appliance — самый дорогой тест в
> плане. spec 08 прямо отмечает (строка 786 для N1-N2, аналогично для R4):
> «реализуемо через `machine.reboot()`», но требует тщательного дизайна driver'а.

---

## 5. overlay-nix (spec 08 §6) — модуль `overlay-nix`

> **Контракт на новый модуль.** Целевогоого модуля
> `services.nixtache.overlay-nix.*` ещё нет — тесты в этой секции **определяют
> его контракт**. Реализующему агенту: создать файл
> `modules/overlay-nix/default.nix` с опциями из §5.1, подключить в `flake.nix` →
> `nixosModules.overlay-nix`, и добиться прохождения всех O-тестов. Маркер кейсов —
> 🆕 NEW MODULE (contract). Требует Nix ≥ 2.19 (experimental feature
> `local-overlay-store`, появилась в 2.19 — см. review §11.5).

### 5.1. Опции модуля (спека 08 §6 — реализующему агенту)

```nix
services.nixtache.overlay-nix = {
  enable   = mkOption types.bool default false;
  upperDir = mkOption types.str default "/var/lib/nix-overlay/upper";
  workDir  = mkOption types.str default "/var/lib/nix-overlay/work";
};
```

> **TODO агенту:** spec 08 упоминает «mergedStore, enableDaemon,
> experimentalFeatures — module-internal» (строка 1118). Это НЕ опции — это
> внутренние derivation-значения. Не выносить в `mkOption`.

### 5.1а. Семантика: overlay-nix = ПОЛНОЦЕННЫЙ рабочий nix

Суть overlay-nix — вернуть **полноценный рабочий nix** на A/B appliance (где
`nix.enable=false` от `image-based-appliance` profile и `/nix/store` — ro
squashFS). Не «поднять отдельный nix-daemon для nix-store-операций», а чтобы
команды работали **как у обычного nix**: `nix shell`, `nix run`, `nix build`,
`nix-store`, `nix-env`, `nix profile`, GC. Единственная ограниченная операция —
GC **не удаляет** пути из lower store (lower ro, `ignore-gc-delete-failure=true`
→ delete-failure печатается как warning, lower untouched). Всё остальное — полный
nix.

**Re-enable nix БЕЗ mkForce (review-пункт):** `image-based-appliance` profile
ставит `nix.enable = false` приоритетом **normal (1000)** (проверено в
`nixos/modules/profiles/image-based-appliance.nix:16` — не mkDefault, не mkForce).
Поэтому чистый обход — **высокий приоритет, не mkForce**:

```nix
config = lib.mkIf cfg.enable {
  # Beats the appliance profile's normal-priority (1000) `nix.enable = false`
  # without mkForce. Brings back nix package + nix.conf + nix-daemon — then
  # re-points the daemon at the local-overlay store.
  nix.enable = lib.mkOverride 900 true;

  # The daemon serves the local-overlay store instead of the (ro) local one.
  # Full nix semantics; GC deletes only from upper (lower ro, failures ignored).
  nix.settings = {
    store = "local-overlay://?lower-store=/nix/store&upper-layer=${cfg.upperDir}";
    extra-experimental-features = [ "local-overlay-store" ];
    ignore-gc-delete-failure = true;
  };
};
```

> **Примечание:** точная схема daemon'а (переписать `nix.settings.store` в
> `local-overlay://` ИЛИ отдельный `nix-daemon-overlay.service` с системным
> daemon как `lower-store=daemon`) — выбор реализующего. Для runner-overlay
> (spec 08 §8) `lower-store=daemon` (spec §8 строки 1385–1389); для host-side
> overlay-nix lower — это ro squashFS `/nix/store` напрямую. Тест O2/O3
> (`overlay-nix-install-vm.nix`) опирается на `nix-store`/`nix` работающие через
> default-сокет — модуль должен сделать overlay-store активным store для
> nix-команд (не только побочный daemon).

### 5.2. O1 — `overlay-nix-mount` (runNixOSTest)

**ID:** `08-O1`
**Цель:** OverlayFS mount поднимается: lower=squashFS, upper=root FS; сервис
`nix-daemon-overlay.service` активен. spec 08 §6 строки 1122–1140.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest (поверх A/B appliance VM).
**KVM:** ✅.
**приоритет:** P0 (топовая пушка).

**Setup:** A/B appliance (через `ab-fixture.nix mkAppliance`) + overlay-nix:
```nix
services.nixtache.overlay-nix = {
  enable = true;
  upperDir = "/var/lib/nix-overlay/upper";
  workDir = "/var/lib/nix-overlay/work";
};
```

**Assertions:**
- `overlayMounted`: `mount | grep overlay | grep /nix/store` (или merged mount point из spec — `/mnt/nix-overlay/nix/store`; **УТОЧНИТЬ** точку монтирования, см. review §11.4).
- `overlayDaemonActive`: `systemctl is-active nix-daemon-overlay` == `active`.
- `experimentalFeatureEnabled`: `nix show-config | grep local-overlay-store` (или в `/etc/nix/nix.conf`).
- `tmpfilesCreated`: директории upper/work существуют (`test -d /var/lib/nix-overlay/{upper,work}`).

### 5.3. O2 — `overlay-nix-install` (runNixOSTest)

**ID:** `08-O2`
**Цель:** `nix-env -iA nixpkgs.hello` ставит пакет в upper layer; binary работает.
spec 08 §6 строки 1142–1150.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**KVM:** ✅.
**приоритет:** P0.

**Setup:** как O1.

**Assertions:**
- `installSucceeds`: `nix-env -iA nixpkgs.hello` exit 0.
- `helloWorks`: `hello` выводит ожидаемое.
- `pathInUpper`: store path пакета в `/var/lib/nix-overlay/upper/` (`test -d
  /var/lib/nix-overlay/upper/nix/store/<hash>-hello-*`).

### 5.4. O3 — `overlay-nix-shell` (runNixOSTest)

**ID:** `08-O3`
**Цель:** `nix shell nixpkgs#cowsay -c cowsay moo` работает.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**приоритет:** P0.

**Assertions:**
- `shellExit0`: команда exit 0.
- `outputContains`: stdout содержит `moo`.

### 5.5. O4 — `overlay-nix-gc` (runNixOSTest)

**ID:** `08-O4`
**Цель:** GC удаляет upper-layer пути, lower не трогает.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Setup:** O2 → `nix-env -e hello` → `nix-collect-garbage`.

**Assertions:**
- `helloGoneFromUpper`: путь hello отсутствует в `/var/lib/nix-overlay/upper/`.
- `lowerIntact`: store paths из squashFS (system closure) остались в нижнем слое
  (`nix path-info /run/current-system` работает).

### 5.6. O5 — `overlay-nix-persistent` (runNixOSTest, reboot)

**ID:** `08-O5`
**Цель:** upperDir на root FS (persistent) → после reboot пакеты сохраняются.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest (`machine.reboot()`).
**приоритет:** P1.

**Setup:** `upperDir = "/var/lib/nix-overlay/upper"` (root FS). Install `vim`
перед reboot.

**Assertions:**
- `vimSurvivesReboot`: после `machine.reboot()` — `vim --version` работает.

### 5.7. O6 — `overlay-nix-tmpfs` (runNixOSTest, reboot)

**ID:** `08-O6`
**Цель:** upperDir на tmpfs → после reboot пакеты **теряются** (by design).
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Setup:** `upperDir = "/tmp/nix-overlay/upper"` (tmpfs). Install `vim`, reboot.

**Assertions:**
- `vimGoneAfterReboot`: `vim --version` fails (exit ≠ 0).
- `overlayRemounts`: overlay mount всё ещё active после reboot.

### 5.8. O7 — `overlay-nix-lower-readonly` (runNixOSTest)

**ID:** `08-O7`
**Цель:** lower store (squashFS) **не модифицируется** overlay-операциями.
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Setup:** capture хэш/размер squashFS партиции до (`dd if=/dev/disk/by-partlabel/nix-store_1 | sha256sum`),
install пакет через overlay, capture снова.

**Assertions:**
- `lowerChecksumUnchanged`: хэш до == после.

### 5.9. O8 — `overlay-nix-path-info` (runNixOSTest)

**ID:** `08-O8`
**Цель:** `nix path-info` видит оба слоя (lower + upper).
**Статус:** 🆕 NEW MODULE.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Setup:** system closure в lower + `hello` в upper (O2).

**Assertions:**
- `bothListed`: `nix path-info --all` содержит и путь system closure, и путь hello.

### 5.10. O9 — `overlay-nix-ab-swap` (pexpect-QEMU, сложный)

**ID:** `08-O9`
**Цель:** после A/B swap: new lower (v2 store) + same upper (persistent) → tool
из upper всё ещё доступен + v2 пути видны.
**Статус:** 🆕 NEW MODULE.
**Тип:** pexpect-QEMU (2-boot).
**приоритет:** P1.

**Setup:** boot v1 + overlay → install tool → sysupdate → boot v2.

**Assertions:**
- `toolStillAvailable`: tool из upper работает после swap.
- `v2PathsVisible`: новые v2 пути в merged store.

---

## 6. nixos-anywhere migration (spec 08 §1-A) — N1, N2

> spec 08 прямо отмечает (строки 783–786): «сложно в runNixOSTest (нужен kexec
> внутри VM + SSH из outer → inner)». Тесты помечены 📋 DOCS/MANUAL —
> автоматизация дорогая и хрупкая.

### 6.1. N1 — `ab-nixos-anywhere` 📋 MANUAL

> Автоматический вариант N1 реализован: `checks.x86_64-linux.ab-ota-anywhere-vm`
> (полный OTA-lifecycle: kexec → disko A/B → UKI boot → signed v2 sysupdate).
> Ручной runbook — `doc/specs/direct-deploy/10-nixos-anywhere-runbook.md`.

**ID:** `08-N1`
**Цель:** kexec → disko → install → boot on A/B.
**Статус:** 📋 DOCS/MANUAL (nixtache не генерирует disko-конфиг — spec 08 §1-A
строки 125–128).
**Тип:** manual runbook (документировать в `doc/specs/direct-deploy/` как
integration-test steps).
**приоритет:** P3.

**Что задокументировать как «тест»:**
1. Команда `nix run github:nix-community/nixos-anywhere -- --flake .#server-ab-image --target-host root@server --disko-mode destroy,format,mount`.
2. Post-conditions для ручной проверки: `sgdisk -p /dev/nvme0n1 | grep -E
   'nix-store_1|_empty'`; `mount | grep /nix/store | grep squashfs` (или erofs);
   `systemctl is-active systemd-sysupdate.timer`.

> Если автоматизировать: multi-stage runNixOSTest (outer VM запускает
> nixos-anywhere на inner VM). spec 08 отмечает как «may stay manual».

### 6.2. N2 — `ab-nixos-anywhere-hostkeys` 📋 MANUAL

**ID:** `08-N2`
**Цель:** `--copy-host-keys` сохраняет SSH host keys между reinstall.
**Статус:** 📋 DOCS/MANUAL.
**Тип:** manual runbook.
**приоритет:** P3.

**Assertions (ручные):** SSH host key fingerprint до == после reinstall.

---

## 7. Runner store overlay (spec 08 §8) — опция `store.mode`

> **Контракт на новую опцию.** Опции `services.nixtache.runner.store.mode` ещё
> нет — тесты в этой секции **определяют её контракт**. Реализующему агенту:
> добавить в `modules/runner/store.nix` (`mkOption types.enum ["clone"
> "overlay"] default "clone"`) + соответствующий `config` под поведение из
> spec 08 §8 строки 1325–1454, и добиться прохождения всех RO-тестов. Маркер
> кейсов — 🔧 NEW OPTION (contract). Требует Nix ≥ 2.19 (`local-overlay-store`).

### 7.1. Опция (спека 08 §8 — реализующему агенту)

```nix
services.nixtache.runner.store.mode = mkOption {
  type = types.enum [ "clone" "overlay" ];
  default = "clone";
  description = "...";  # spec 08 строки 1437–1454
};
```

Поведение `mode = "overlay"`: `nix-daemon-overlay-mount.service` (mount OverlayFS)
заменяет `nix-daemon-storage.service` (clone); `nix-daemon-custom` использует
`local-overlay://` store URL (spec 08 §8 строки 1348–1395).

### 7.2. RO1 — `runner-overlay-mount` (runNixOSTest)

**ID:** `08-RO1`
**Цель:** `store.mode = "overlay"` → OverlayFS mount поднимается, **нет**
`nix-daemon-storage` (clone). spec 08 §8 строки 1345–1377.
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest.
**KVM:** ✅.
**приоритет:** P0.

**Setup:** `services.nixtache.runner = { enable=true; store.path="/srv";
store.mode="overlay"; ... }`.

**Assertions:**
- `overlayMounted`: `mount | grep overlay | grep /srv/nix/store`.
- `noCloneService`: `! systemctl list-unit-files | grep nix-daemon-storage` (сервис не провижинится при overlay).
- `overlayMountServiceActive`: `systemctl is-active nix-daemon-overlay-mount`.
- `customDaemonActive`: `systemctl is-active nix-daemon-custom`.

### 7.3. RO2 — `runner-overlay-no-clone` (runNixOSTest)

**ID:** `08-RO2`
**Цель:** `nix copy --all` НЕ вызывается (boot быстрее).
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest.
**приоритет:** P0.

**Setup:** как RO1.

**Assertions:**
- `noNixCopyInLogs`: `! journalctl -u nix-daemon-storage | grep "nix copy"` (сервиса нет → логов нет).
- `mountInstant`: время старта `nix-daemon-overlay-mount` < 5 сек (`systemctl
  show -p ExecMainStartTimestamp` сравнить с boot).

### 7.4. RO3 — `runner-overlay-build` (runNixOSTest)

**ID:** `08-RO3`
**Цель:** CI build пишет в overlay upper, binary работает.
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest.
**приоритет:** P0.

**Assertions:**
- `buildSucceeds`: `nix build` exit 0.
- `outputInUpper`: output в `/srv/overlay/upper/` (путь из spec 08 §8 строка 1369).
- `binaryRuns`: собранный binary выполняется.

### 7.5. RO4 — `runner-overlay-read-lower` (runNixOSTest)

**ID:** `08-RO4`
**Цель:** существующие пути (из squashFS/lower) видны через overlay.
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Assertions:**
- `lowerPathsVisible`: `nix path-info /run/current-system` работает (путь из lower).

### 7.6. RO5 — `runner-overlay-gc` (runNixOSTest)

**ID:** `08-RO5`
**Цель:** GC удаляет upper пути, lower не трогает.
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest.
**приоритет:** P1.

**Assertions:**
- `upperPathGone`: после `nix-collect-garbage` — build output (RO3) удалён из upper.
- `lowerIntact`: lower пути (system closure) доступны.

### 7.7. RO6 — `runner-overlay-ab-swap` (pexpect-QEMU, сложный)

**ID:** `08-RO6`
**Цель:** после A/B swap: new lower (v2) + same upper (persistent).
**Статус:** 🔧 NEW OPTION.
**Тип:** pexpect-QEMU (2-boot).
**приоритет:** P1.

**Assertions:**
- `v2PathsVisible`: v2 lower пути видны.
- `ciOutputPersistent`: build output из upper (до swap) доступен после.

### 7.8. RO7 — `runner-overlay-boot-time` (benchmark, опц.)

**ID:** `08-RO7`
**Цель:** boot с overlay быстрее чем clone.
**Статус:** 🔧 NEW OPTION.
**Тип:** runNixOSTest (2 VM, benchmark).
**приоритет:** P2.

**Setup:** 2 VM: `mode="clone"` vs `mode="overlay"`. Измерить время от boot до
`nix-daemon-custom active`.

**Assertions:**
- `overlayFaster`: `t(overlay) < t(clone)` (допуск: измерение в CI шумное;
  утвердить как «overlay ≤ clone», не строгое кратное).

> ⚠️ **RESOLVED (review §11.5):** `local-overlay-store` появилась в **Nix 2.19**
> (не 2.35). Реализующему агенту: assert в `store.nix` — `mode="overlay"`
> требует `lib.versionAtLeast config.nix.package.version "2.19"`. Тест
> `08-RO-ASSERT` на этот assert (pure-eval).

---

## 8. Таблица покрытия опций (coverage matrix)

> Правило из `AGENTS.md` nixtache: «every consumer-facing `mkOption` gets at
> least one assertion in `tests/`». Ниже — каждая опция → тест(ы), которые её
> покрывают. **Жирным** — опции, не имеющие теста после реализации этой спеки
> (gap, требующий внимания).

### 8.1. `services.nixtache.ab-image.*` (модуль есть)

| Опция | Тип | Покрытие | Тест |
|---|---|---|---|
| `enable` | bool | ✅ | `ab-image` scenarioFixed + все ab-VM |
| `imageId` | str | ✅ | scenarioFixed (imageId в MatchPattern) |
| `imageVersion` | str | ✅ | scenarioFixed |
| `stagingPath` | str | ✅ | ab-ota-e2e (http://), ab-vm (file://) |
| `storeSize` | str | ✅ | scenarioFixed/maxDisk; **S4** (percent) |
| `storeFs` | enum | ✅ K-секции | **K2/K4** (erofs) |
| `storeCompression` | null\|str | ✅ | **§3.0** (wiring) + **K1/K3** |
| `storeCompressionLevel` | null\|int | ✅ | **§3.0** + **K3** |
| `rootSize` | str | ✅ | scenarioFixed |
| `diskSize` | null\|str | ✅ | scenarioMaxDisk |
| `ukiTries` | int | ⚠️ **GAP** | не покрыт (нет теста на boot-counting tries) |
| `publicKeyFile` | null\|path | ✅ | scenarioSigned |
| `publicKey` | null\|str | ✅ | scenarioSigned (использует publicKey) |
| `extraPartitions` | attrsOf | ✅ | ab-vm T6 (data partition) |
| `transfers` | attrsOf | ✅ | ab-ota-e2e (custom transfers) |

> **GAP `ukiTries`:** добавить pure-eval проверку — при `ukiTries=5` →
> `config.boot.uki.tries == 5`. Минимальный сценарий в `tests/ab-image.nix`.

### 8.2. `services.nixtache.deploy-target.ab.*` (модуль есть)

| Опция | Покрытие | Тест |
|---|---|---|
| `enable` | ✅ | scenarioAb + ab-ota-e2e |
| `gating` | ✅ | scenarioAbGating |
| `idleWaitTimeout` | ✅ | scenarioAbGating (600 в script) |
| `forceAfterTimeout` | ⚠️ partial | **V4** (добирает) |
| `forgejoApiTokenFile` | ✅ | scenarioAbGating + assertNoToken |

### 8.3. `services.nixtache.runner.deploy.ab.*` (модуль есть)

| Опция | Покрытие | Тест |
|---|---|---|
| `enable` | ✅ | scenarioAbStage |
| `stagingPath` | ✅ | scenarioAbBasenameAssert |
| `runnerHost` | ✅ | scenarioAbStage + **V3** |
| `nginx.location` | ✅ | scenarioAbStage + basename-assert |
| `retain` | ⚠️ partial | **V1** (добирает retain=2 в script) |
| `signingKeyFile` | ✅ | scenarioAbStage (LoadCredential) |

### 8.4. `services.nixtache.runner.store.*` (модуль есть)

| Опция | Покрытие | Тест |
|---|---|---|
| `path` | ✅ | scenarioSrv/Root + **R3** (assert vs ab-image) |
| `hostBackup` | ⚠️ **GAP** | не покрыт (нет теста что bind-mount host→container) |
| **`mode`** 🔧 | 🔧 NEW | **RO1–RO7** |

> **GAP `hostBackup`:** pure-eval — `bindMounts."srv-nix".hostPath ==
> cfg.store.hostBackup`.

### 8.5. `services.nixtache.deploy-target.ab.partitions.*` 🆕 (новый модуль)

| Опция | Покрытие | Тест |
|---|---|---|
| `enable` | 🆕 | **P5** (enable + regular-file → no service) |
| `slot_a.type` | 🆕 | **P5**, **A1** (assert type mismatch) |
| `slot_a.storage` | 🆕 | **P3** (second disk), **P4** (diff disks), **A4** |
| `slot_a.label` | 🆕 | **P1** (nix-store_1) |
| `slot_b.type` | 🆕 | **A1** |
| `slot_b.storage` | 🆕 | **P4** |
| `slot_b.label` | 🆕 | **P1** (_empty) |
| `slotSize` | 🆕 | **P1** (abs), **S4** (%), **A2** (assert vs storeSize) |
| `autoInit` | 🆕 | **P1** (true), **A3**, **A5** (false assert) |
| `onSizeMismatch` | 🆕 | **S1** (error), **S2** (wipe) |
| `protectedLabels` | 🆕 | **PR1** |
| `source` | 🆕 | **ab-contract** (url → url-file, local → file://), **A1** (e2e remote) |
| `imageId` | 🆕 | **ab-contract** (MatchPattern из imageId / fallback "nixtache") |
| `verify` | 🆕 | **ab-contract** (**A5**: verify без ключа → refuse), **C1–C4** |
| `publicKeyFile` | 🆕 | **ab-contract** (Verify=yes + pubring в /etc), **C-setup** |
| `publicKey` | 🆕 | **ab-contract** (**A6**: file+key вместе → refuse) |
| `bootTarget` | 🆕 | **ab-contract** (auto → ESP $BOOT; /dir → Path=dir), **A1** (e2e) |

> `mountPoint` убран из контракта (review §11.6 — избыточная опция; монтирование
> знает `ab-image` из repart labels, provision знает **где партиции**, не куда
> монтировать).

### 8.6. `services.nixtache.overlay-nix.*` 🆕 (новый модуль)

| Опция | Покрытие | Тест |
|---|---|---|
| `enable` | 🆕 | **O1** |
| `upperDir` | 🆕 | **O5** (persistent), **O6** (tmpfs) |
| `workDir` | 🆕 | **O1** (tmpfilesCreated) |

### 8.7. `services.nixtache.runner.store.mode` 🔧 (новая опция)

| Опция | Покрытие | Тест |
|---|---|---|
| `mode` | 🔧 | **RO1–RO7** + assert на Nix ≥ 2.19 (review §11.5) |

---

## 9. Сводка: новые тест-файлы и подключения в flake.nix

Реализующему агенту: после написания каждого файла — добавить в `flake.nix`:

```nix
checks = forAllSystems (system: {
  # ... существующие ...
  ab-compression   = import ./tests/ab-compression.nix  { inherit nixpkgs self system; };  # K1-K3 (+ §3.0 pure-eval)
  ab-provision     = import ./tests/ab-provision.nix    { inherit nixpkgs self system; };  # P/S/PR pure-eval asserts
  # runNixOSTest (тяжёлые, KVM):
  ab-provision-vm  = import ./tests/ab-provision-vm.nix { inherit nixpkgs self system; };  # P1-P5, S1-S3, PR1 (requiredSystemFeatures=["kvm"] внутри runNixOSTest? — НЕТ, runNixOSTest сам ставит; но см. примечание)
  overlay-nix      = import ./tests/overlay-nix.nix     { inherit nixpkgs self system; };  # O1-O9
  runner-overlay   = import ./tests/runner-overlay.nix  { inherit nixpkgs self system; };  # RO1-RO7
  ab-runner-compat = import ./tests/ab-runner-compat.nix{ inherit nixpkgs self system; };  # R1-R3 (R3 pure-eval можно в существующий runner.nix)
});
```

> **KVM-маркировка:** `runNixOSTest` и pexpect-QEMU требуют KVM. У существующих
> тяжелых тестов (`ab-vm`, `ab-ota-e2e`) `requiredSystemFeatures = ["kvm"]`
> ставится внутри (см. `ab-vm.nix` строка 193). Новые тяжёлые — делать так же,
> иначе `nix flake check` на runner'е в nspawn упадёт.

> **Группировка:** spec 08 разделяет pure-eval asserts (быстрые, в каждый
> `nix flake check`) и VM-тесты (тяжёлые, по требованию). Рекомендация:
> pure-eval проверку опций (wiring/service existence/script text/asserts) держать
> в лёгких `*-test.nix` (как `ab-image.nix`), а runtime-поведение — в
> `*-vm.nix`/`runNixOSTest`.

---

## 10. Приоритеты (из spec 08 §«Приоритеты реализации», строки 788–802)

| Приоритет | Тесты | Примечание |
|---|---|---|
| **P0** (топ-пушка) | **O1, O2, O3**, **RO1, RO2, RO3** | overlay-nix + runner-overlay — базовая функциональность |
| **P0** (existing) | A1 (ab-ota-e2e — ✅ на provision-модуле) | §1а.1 |
| **P0** (implement next) | **B1**, **C1, C2** | self-deploy + signature verification — ядро A/B (§1а.3, §1а.7) |
| **P1** | **P1–P5, S1–S4**, **K1, K4**, **R1, R2, R3**, V1, V2, O4, O5, O7, O8, RO4, RO5 | provisioning + runner-compat + compression core |
| **P2** | V3, V4, **PR1**, **K2, K3**, R4, O6, O9, RO6, RO7, **A2–A5**, **B2–B4**, **C3, C4** | edge cases / benchmarks / deploy-варианты |
| **P3** | **N1, N2** | nixos-anywhere (may stay manual) |

---

## 11. Review: неоднозначности и пробелы в спеках 06/08

> То, что реализующий агент должен либо уточнить у автора спеки, либо принять
> решение и зафиксировать в модуле. Каждое — с указанием строки.

### 11.1. GC и подписанный staging — РЕШЕНО: GC переподписывает если ключ доступен ✅

**Модель подписи (уточнение автора):** приватный GPG-ключ идёт как **host-path**
(`signingKeyFile` — sops-секрет на host FS). Контейнер получает его через
LoadCredential `sysupdate_signing_key`, **но host тоже может читать его
напрямую** (sops расшифровывает в реальный файл на диске). Публичный ключ — путь
на каждом target'е (`publicKeyFile`/`publicKey` → `/etc/systemd/import-pubring.pgp`).
Старый комментарий «the key isn't on the host» был **неправ** — поэтому исходная
реализация не переподписывала и ломала `Verify=yes`.

**Баг (исходно):** GC удалял старые файлы версий → `SHA256SUMS` regenerated
(новый контент) → `SHA256SUMS.gpg` НЕ ТРОНУТ (старая подпись над прошлым списком)
→ remote target с `Transfer.Verify=yes`: `gpgme: signature mismatch` → REJECT →
нет обновлений.

**Фикс (реализован в `modules/runner/ab.nix`, runner-test зелёный):**
```
GC прогон → удаляет старые <id>_<v>.{raw,efi}
         → SHA256SUMS regenerated (из выживших)
         → signingKeyFile != null?
            ├─ YES (+ файл существует) → gpg --detach-sign → SHA256SUMS.gpg обновлён ✓
            ├─ YES (файл пропал)        → rm SHA256SUMS.gpg  (нет подписи → нет stale)
            └─ NO  (ключ не настроен)   → rm SHA256SUMS.gpg
```
Ключевой insight: `signingKeyFile` — host-path, доступен GC на host'е; gpg
добавлен в `path` сервиса когда ключ задан (`++ optional (signingKeyFile !=
null) gnupg`).

**Тест V1** (`tests/ab-existing.nix`, зелёный) теперь покрывает:
- `retainInScript` / `sortsDesc` / `removesRawAndEfi` — GC-логика удаления;
- `regenSums` — регенерация SHA256SUMS;
- `reSignsWhenKey` — `gpg --batch --yes --detach-sign` присутствует когда
  `signingKeyFile` задан;
- `gnupgInPath` — gnupg в `path` сервиса когда ключ задан;
- отдельный сценарий `signingKeyFile=null` → скрипт содержит `rm ... SHA256SUMS.gpg`
  и НЕ содержит `detach-sign`.

### 11.2. Дублирование `testSignKey` — РЕШЕНО: рефактор ab-vm ✅

`tests/ab-vm.nix` дублировал `testSignKey` из `tests/ab-fixture.nix`.
**Сделано:** `ab-vm.nix` переведён на общий fixture (`import ./ab-fixture.nix`),
локальный `testSignKey` удалён. См. commit рефактора.

### 11.3. appliance `nix.enable=false` vs nix-daemon — РЕШЕНО автором ✅

`image-based-appliance` profile форсит `nix.enable=false`. **Идея автора:** с
upper store (overlay включён) `nix` и `nix-daemon` **рабочие** — overlay даёт
writable store поверх ro squashFS. Если же overlay НЕ включён (чистый A/B
readonly) — в контейнере должен быть **только один** `nix-daemon-custom`, который
**НЕ ждёт** системный `nix-daemon.service`.

**Действие для реализующего (`modules/runner/store.nix`):** `nix-daemon-storage`
(oneshot clone) имеет `requires = [ "nix-daemon.service" ]` (строка 174). На A/B
appliance без overlay системного `nix-daemon.service` нет → storage не стартует.
Решение: `requires` должен быть **условным** — зависеть от `nix-daemon.service`
только когда этот сервис существует (т.е. `nix.enable=true` / не appliance).
Конкретно:
- `mode = "overlay"`: storage отсутствует вовсе (overlay-mount его заменяет);
  `nix-daemon-custom` работает через overlay store — `nix` доступен.
- `mode = "clone"` на НЕ-appliance (`nix.enable=true`): как сейчас, `requires =
  [ "nix-daemon.service" ]`.
- `mode = "clone"` на appliance БЕЗ overlay: `nix-daemon-custom` не требует
  `nix-daemon.service` (один, автономно).

Тесты R1/R2 (`ab-runner-compat-vm.nix`) должны покрывать оба режима; до правки
`store.nix` R1/R2 красные по правильной причине.

### 11.4. local-overlay-store: модель монтирования — РЕШЕНО через доку ✅

Перечитана офиц. дока
(https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html).
Ключёвые факты, снимающие неоднозначность:

- **Модуль сам монтирует OverlayFS** — Nix это НЕ делает (но проверяет монтаж
  через `check-mount=true` по умолчанию, сверяя lowerdir/upperdir с настройками).
- Store URL: `local-overlay://?root=<R>&lower-store=<L>&upper-layer=<U>`.
  - lower store dir = `<L>/nix/store` — **иммутабельный** (mount ro + `read-only=true`).
  - upper layer = `<U>` — **read/write**, вне squashFS (на root-FS / отдельной партиции).
  - merged store dir = **`<R>/nix/store`** — куда монтируется OverlayFS (`lowerdir=<L>/nix/store`, `upperdir=<U>`, `workdir=<W>` на той же ФС, что `<U>`).
- `ignore-gc-delete-failure=true` — GC удаляет upper-пути; lower НЕ трогает
  (lower ro, delete-failure игнорируется как warning).
- upper почти-local-store: отдельная SQLite DB в `${state}/db` (дублирует часть
  lower-метаданных для замкнутости closure upper'а).

**Для spec 08 §6 (overlay-nix, host-side ad-hoc nix):** merged монтируется в
`<R>/nix/store` где `R` = root модуля (не обязательно overmount `/nix/store`).
Достаточно поднять OverlayFS с lower=squashFS `/nix/store` (ro) и upper=
`upperDir` (rw), merged в выбранный root, и запустить `nix-daemon` с этим store
URL + `extra-experimental-features = local-overlay-store`.

**Для тестов O-серии:** assertion O1 не должен хардкодить точку монтирования
(`/nix/store` overmount vs `/mnt/...`) — detect'ить overlay из `mount` и
проверять, что upperdir = настроенный `upperDir`, а lower — ro. Текущий
`overlay-nix-vm.nix` так и делает (COW-пруф через запись в merged → файл в
upperDir). Корректно.

### 11.5. Версия Nix для local-overlay-store — РЕШЕНО: 2.19, не 2.35 ✅

Research (nix.dev manual + release notes): experimental feature
`local-overlay-store` появилась в **Nix 2.19 (2023-11-17)** — НЕ 2.35 (URL доки
`/2.35/` вводил в заблуждение; фича стабильно в manual с 2.22). Значит assert
должен требовать **Nix ≥ 2.19**, а не 2.35. Спека §5/§6/§8 везде правит «≥ 2.35»
на «≥ 2.19».

**Assert для реализующего** (`modules/runner/store.nix` для `mode="overlay"` и
`modules/overlay-nix/default.nix` для `enable=true`):
```nix
{ assertion = !cfg.enable || lib.versionAtLeast config.nix.package.version "2.19";
  message = "local-overlay-store requires Nix >= 2.19 (experimental feature)."; }
```
Тест `08-RO-ASSERT` / `08-O-ASSERT` (pure-eval) на этот assert.

### 11.6. `partitions.mountPoint` — РЕШЕНО: опция избыточна, убрана ✅

Автор: `mountPoint` — избыточная опция. `ab-image` уже знает что монтировать (из
repart labels → `fileSystems`). Provision-модуль знает **где партиции**
(`slot_a`/`slot_b.storage`), но **не куда их монтировать** — это не его concern.
**Опция убрана из спеки 08 §4.** Тест `08-P-MOUNT` не нужен; coverage matrix §8.5
`mountPoint`-строка удалена.

### 11.7. sysupdate transfers: конфликт ab-image vs ab-provision — РЕШЕНО ✅

Автор дал чёткое разделение владения:

| Модуль | Роль | Transfers? |
|---|---|---|
| `ab-image` | Build-time: repart image, UKI, sysupdate-package | **`mkDefault`** — fallback для standalone (тесты, `ab-vm` без provision) |
| `ab-provision` | Runtime: slot layout, provision service, polkit, gating | **normal priority** — единственный автор когда активен |

`ab-provision` знает про `slot_a`/`slot_b` (разные диски? partition vs file?
InstancesMax 1 или 2?) — он владеет transfer-деривацией. `ab-image` хардкодит
`Path = "auto"` и не знает про слоты.

**Действие для реализующего:**
- `modules/ab-image/default.nix` строка 385: `systemd.sysupdate.transfers =
  lib.mkDefault cfg.transfers;` (было normal priority).
- `modules/deploy-target/ab-provision.nix`: `systemd.sysupdate.transfers =
  derivedFromSlots;` (normal priority) — когда `partitions.enable = true`, он
  перекрывает mkDefault без конфликта.
- Когда `partitions.enable = false` (standalone ab-image, напр. `ab-vm` без
  provision) — работает mkDefault-fallback из ab-image. Никаких
  duplicate-definition.

Тесты P4 (`ab-contract.nix` + `ab-provision-vm.nix`) проверяют что transfer'ы
деривируются из slot-конфига (2 transfer'а на different-disks, 1 на same-disk).
После реализации ab-provision как sole owner — зелёные.

### 11.8. S2 wipe + detection — РЕШЕНО: stateless via GPT label count ✅

Detection-скрипт (spec 08 §2) и дерево решений — **stateless через подсчёт GPT
labels**, без state-файла. Модель меток sysupdate-native: записанный слот несёт
`nix-store_<v>`, свободный — `_empty` (хардкод systemd-sysupdate: он ищет
свободный слот по точной метке `_empty`, записывает его и переименовывает в
`nix-store_<v>`; vacuum старой версии возвращает метку `_empty`). Два состояния
определяются по `lsblk -no PARTLABEL`:

| Состояние | Признак | Действие provision |
|---|---|---|
| **Normal** | `nix-store_[0-9]` + `_empty` ≥ 1 | проверить размер (§3) |
| **Missing** | 0 slot-меток | миграция (autoInit / assert) |

**Это снимает исходную проблему:** раньше detection проверял только
`nix-store_[0-9]` → после wipe считал что слотов нет → входил в миграцию →
бесконечный цикл / assertion. Теперь wipe (§3) пересоздаёт ту же пару
`nix-store_1 + _empty`, что и autoInit, — на следующем boot'е это Normal с
совпадающими размерами → provision **no-op** (`exit 0`), sysupdate заполняет
`_empty` при следующем deploy. State-файл `ab-needs-initial-deploy` **убран**
из §3 (не нужен — состояние выводится из GPT каждый boot).

**Тест S2** (`ab-provision-vm.nix`) проверяет: после wipe (а) обе партиции
пересозданы с метками `nix-store_1` + `_empty` нового размера, (б) **на
повторном запуске provision** таблица разделов не меняется (идемпотентность —
Normal detected, размеры совпадают).

### 11.9. `nixtache-ab-apply` `set -uo pipefail` — РЕШЕНО: код корректен ✅

Line-by-line трейс (автор): `set -uo pipefail` (без `-e`) — intentional. Все
failure-mode'ы curl/jq ведут к `busy=1` через `|| echo 1` (fail-safe: при любой
неопределённости **ждём**, не применяем вслепую). Цикл **bounded** —
`idleWaitTimeout` (1800s дефолт), не infinite. `set -e` здесь **нельзя** —
прервал бы на кратковременных сбоях Forgejo/сети.

Единственное улучшение — **косметика** (observability): залогировать причину
fallback в journal:
```bash
busy=$(curl -sf ... | jq '...' 2>/dev/null \
  || { echo "nixtache-ab-apply: Forgejo API unreachable, treating as busy" >&2; echo 1; })
```
Не баг. Покроется тестами B2/B3 (gating busy/idle) когда сценарий B зайдёт в скоуп.

---

## 12. Какой nix-тест покрывает какой test-case

> Реализованные `.nix`-файлы в `tests/` → какие кейсы из этой спеки они покрывают.
> Все подключены в `flake.nix` → `checks.x86_64-linux.<name>`.
> **Сигнал зелёное/красное:** pure-eval	suite (ab-existing, ab-contract) — `nix eval .#checks.x86_64-linux.<name>.report --raw` печатает отчёт (зелёное = все `ok`, красное = `FAIL`); QEMU-suite (`*-vm.nix`) — `nix build .#checks.x86_64-linux.<name>` (нужен KVM).

### 12.1. Pure-eval suites (быстро, без KVM)

| Файл | Статус сейчас | Покрывает кейсы (TEST-SPECS §) |
|---|---|---|
| `tests/ab-existing.nix` | 🟢 ALL GREEN (21 ok) | §3.0 (compression wiring: storeFs/storeCompression/storeCompressionLevel/null), **K-wiring**, V1 (retain-script **+ GC re-sign при signingKeyFile, drop .gpg без ключа**, §11.1), V2 (cache-assert), V3 (runnerHost-assert), hostBackup (gap), V4 (forceAfterTimeout branch), R3 (native-store assert), ukiTries (gap) |
| `tests/ab-contract.nix` | 🔴 RED до реализации (graceful) | **ab.partitions:** P1 (wiring), P4 (diff-disks / same-disk transfers), P5 (regular-file skip), A1–A4 (asserts, gated по modulePresent); **overlay-nix:** O1 (wiring); **store.mode:** RO1 (overlay services), clone-path |

### 12.2. QEMU suites (runNixOSTest / pexpect, KVM)

| Файл | Статус | Покрывает кейсы (TEST-SPECS §) |
|---|---|---|
| `tests/ab-provision-vm.nix` | 🔴 RED (`ab.partitions does not exist`) | P1 (init), P2 (idempotent), P3 (second-disk), S1 (size-error), S2 (size-wipe), S3 (no-space), S4 (percent), PR1 (protected-label) |
| `tests/overlay-nix-vm.nix` | 🔴 RED (`overlay-nix does not exist`) | O1 (overlay mount + daemon), **read-only lower + overlay COW в upper** (приоритет), O7 (lower-readonly) |
| `tests/overlay-nix-install-vm.nix` | 🔴 RED (`overlay-nix does not exist`) | O2/O3 (install-from-cache): `nix-store --realize hello` из nix-serve-ng (deployer-нода) → **бинарь запускается** → путь в **upper** (COW). Hermetic, без интернета |
| `tests/runner-store-mode-vm.nix` | 🔴 RED (`store.mode does not exist`) | **RO1** (overlay mount в контейнере), RO2 (no clone), RO3+**read-only+overlay proof** (COW: /nix/store ro → write в upper), RO4 (read lower), RO5 (GC semantics) |
| `tests/ab-compression-vm.nix` | 🟢 green на KVM (существующий код) | K1 (squashfs+zstd < none), K2 (erofs+zstd < squashfs+none), K3 (monotonic levels), K4 (boot squashfs + erofs, /nix/store mount) |
| `tests/ab-staging-vm.nix` | 🟢 green на KVM (существующий код) | **V1 real-run**: GC deletes old version + re-signs SHA256SUMS.gpg (verifies against pubring), no-key → drops .gpg (§11.1 end-to-end) |

### 12.3. Существующие suites (не менялись)

| Файл | Покрывает |
|---|---|
| `tests/ab-image.nix` | ab-image fixed/max-disk sizing, Verify (spec 06) |
| `tests/deploy-target.nix` | deploy-target.ab polkit/gating/asserts (spec 06) |
| `tests/runner.nix` | runner.deploy.ab staging/nginx/envs/gc/signing (spec 06) |
| `tests/ab-deploy.nix`, `tests/ab-vm.nix` | E2E staging + appliance boot (spec 06) |
| `tests/ab-ota-e2e.nix` | **A1** (§1а.1): полный deploy-пайплайн; target-нода на provision-модуле (слоты создаёт `nixtache-ab-provision`, transfer Target — из модуля) |

### 12.4. Что НЕ покрыто (gap → после реализации/уточнения)

| Кейс | Где будет | Почему сейчас gap |
|---|---|---|
| O2/O3 (install/run from cache) | `overlay-nix-install-vm.nix` | ✅ покрыт (hermetic nix-serve deployer). Останется gap только для `nix run nixpkgs#hello` с flake-registry (нужен local nixpkgs path, см. коммент в тесте) |
| O4/O5/O6 (GC/persistent/tmpfs) | `overlay-nix-vm.nix` | требуют real nix store ops; O5 multi-boot |
| O9 (overlay ab-swap) | `overlay-nix-vm.nix` | multi-boot pexpect, сложный |
| R1/R2 (runner store-clone/build на A/B) | новый `ab-runner-compat-vm.nix` | ждёт правки store.nix (§11.3) |
| R4 (reclone after swap) | `ab-runner-compat-vm.nix` | multi-boot |
| RO6 (runner overlay ab-swap), RO7 (boot benchmark) | `runner-store-mode-vm.nix` | multi-boot / benchmark |
| N1/N2 (nixos-anywhere) | runbook (manual) | spec 08 сама: «may stay manual» |
| A2–A5 (compression/slotSize варианты A1) | §1а.2, `ab-ota-e2e.nix` (варианты) | спека есть (§1а.2), реализация P2 |
| B1–B4 (self-deploy + gating) | §1а.3–1а.6, новый `ab-deploy-self-vm.nix` | спека есть; open question: `forgejoPort` stub (§1а.4) |
| C1–C4 (signature verification) | §1а.7, `ab-ota-verify-vm.nix` | спека есть, реализация P0 (C1/C2) / P2 (C3/C4) |

---

## 13. Чек-лист для реализующего агента

- [ ] Каждый новый `tests/*.nix` подключён в `flake.nix` `checks.<system>`.
- [ ] Каждый `mkOption` в новом модуле имеет `description` (strict mode docs CI).
- [ ] Тяжёлые тесты (runNixOSTest/pexpect) имеют `requiredSystemFeatures=["kvm"]`.
- [ ] Pure-eval asserts используют `builtins.tryEval (...).config.system.build.toplevel.outPath`.
- [ ] Переиспользуется `tests/ab-fixture.nix` (не дублировать keypair-генерацию).
- [ ] Каждый 🆕/🔧 контракт-тест удовлетворён: реализующий агент создаёт
      модуль/опцию (см. §0.1 пути файлов) так, чтобы контракт-тест загорелся
      зелёным. Тест = принимающий критерий имплементации.
- [ ] Уточнены неоднозначности §11.1, §11.3, §11.4, §11.6, §11.7, §11.8 у автора спеки.
- [ ] `nix flake check --show-trace --all-systems` зелёный; `nix build .#checks.x86_64-linux.<suite>` печатает отчёт.
- [ ] coverage matrix §8 — каждая опция имеет ≥1 теста (GAP закрыты в
      `ab-existing.nix`: `ukiTries`, `hostBackup`; `mountPoint` убран — §11.6).

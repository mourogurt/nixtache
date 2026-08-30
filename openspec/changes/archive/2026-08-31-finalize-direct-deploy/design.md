## Context

Аудит (см. proposal.md — Why) сверил спек-корпус `doc/specs/` с кодом на HEAD `1a0f937`. Реализовано почти всё (батчи A–E, auto-update, ab-provision/overlay-nix/store.mode, ~22 тест-суиты), но: (а) контракт модуль→action сломан в проде и замаскирован тестами с ручным JSON; (б) несколько спекфицированных поведений не реализованы или реализованы ослабленно; (в) deploy-user провижинится как normal user; (г) документация отстаёт от реализации на три фичи. Ключевые точки кода: `modules/runner/deploy.nix:67-80` (сериализация), `.forgejo/actions/deploy-target/action.yml:184-186` (фильтры), `modules/deploy-target/apply.nix:82-89` (rollback), `modules/ab-image/default.nix` (нет `RebootEnable`), `modules/deploy-target/ab-provision.nix:288-291,192-202` (size-mismatch, labels), `modules/deploy-target/ab.nix:216-218` (порядок gating), `modules/deploy-target/user.nix:47-52` (isNormalUser), `modules/auto-update/default.nix:383-414` (A4/A8).

## Goals / Non-Goals

**Goals:**
- Live-deploy работает end-to-end из конфигурации реального модуля (без ручного JSON).
- Tier-1 rollback действительно откатывает живую систему; ab-таргеты доходят до активации.
- Deploy-user — системная, невидимая в DM, минимально привилегированная учётка.
- Вся реализованная поверхность документирована; спек-корпус согласован с кодом.

**Non-Goals:**
- Новый функционал сверх спек 01–09 — кроме `nixtache-apply-dry.service` (D11): это закрытие сломанной в V2 dry-ветки, а не новая фича.
- Batch F (cross-arch) — только pure-eval тест-сценарий `aarch64-linux`, не e2e.
- VM-тесты R4/RO6, N2, AU-F5 — остаются вне скоупа (см. Risks).
- Реализация vCPU-тяжёлых VM-прогонов в CI (правило «vmTests — вручную на KVM-хосте» сохраняется).

## Decisions

### D1. Фикс сериализации: добавить `enable` + `extraOptions` в JSON (не ослаблять action)

Альтернатива — научить action трактовать отсутствующий `enable` как `true` — отвергнута: фильтр `enable=false` обязателен по спеке 01, а «отсутствует = true» стирает разницу между «забыли сериализовать» и «выключено». Правим источник: `deploy.nix` сериализует оба поля; action дополнительно получает safe-default (`// {enable: true}`) как защиту от старых раннеров. Контрактный тест: pure-eval сценарий вычисляет `config.services.nixtache.runner`-env реального модуля → его JSON скармливается bash-фрагменту фильтров action'а (тот же механизм извлечения `run:`-блока из action.yml, что уже используют `ab-deploy.nix`/`ab-deploy-e2e.nix`) → ассерты skip/continue. Это закрывает класс багов «тесты варят JSON руками».

### D2. Rollback: активировать `$prev`, pointer удалять всегда (поправить спеку)

`apply.nix`: rollback вызывает `"$prev/bin/switch-to-configuration" switch` (не `/run/current-system`). Удаление pointer в rollback-ветке СОХРАНЯЕМ (анти-retry: иначе следующий триггер повторно применит сломанный closure) — это осознанное отклонение от буквы 04:115/05:90, заносимое в back-patch спеки (см. D9). Повторный провал rollback-свича не должен маскировать исходную ошибку — `|| true` с логом.

### D3. RebootEnable: через `systemd-sysupdate-reboot.service` (уточнение при имплементации)

Спекой 06 предполагался per-transfer флаг `reboot.enable` — у sysupdate такого
флага **нет** (sysupdate.d(5)); ребут выбирается ЮНИТОМ: `systemd-sysupdate.service`
(только запись слота) vs `systemd-sysupdate-reboot.service` (запись + ребут).
Реализация: remote-ветка action'а и gating-юнит `nixtache-ab-apply` триггерят
**-reboot**-вариант (gating уже подтвердил idle раннеров — ребут безопасен);
polkit-правило допускает оба юнита. Новая опция не вводилась; спека 06
back-patched под фактический механизм.

### D4. Slot labels: дефолты `nix-store_1`/`_empty` в опциях

Прямо по спеке 08 §4. Mенять `label = mkOption { default = "nix-store_1"; }` вместо текущего `null`. Идемпотентность доказывается существующим P2-сценарием без явных labels.

### D5. Gating: `rm` после успешного старта sysupdate

Инверсия порядка в `ab.nix` + тест в `ab-deploy-self-vm` (маскируем sysupdate → флаг жив → размаскируем → повтор срабатывает).

### D6. Size-mismatch=error: маскирование sysupdate

Механизм: provisioning-скрипт при error-миссмаче выполняет `systemctl mask systemd-sysupdate.service` (переживает ребут, блокирует и timer, и path-триггеры) и `exit 1`; размаскирование — ручное (`systemctl unmask` + устранение конфликта + повтор). Альтернатива `systemctl stop` отвергнута: timer поднял бы юнит обратно. Тест — расширение S1-сценария `ab-provision-vm` ассертом `systemctl is-masked systemd-sysupdate`.

### D7. Deploy-user: `isSystemUser` + удаление `nixTrust` (trust стал безусловным — уточнение при имплементации)

`user.nix`: `isSystemUser = true; isNormalUser = false; useDefaultShell = true;` (nologin заблокировал бы даже ForcedCommand-гейт), `group = "nixtache-deploy"`, без `createHome`. SDDM не показывает системные uid (<1000). Для `autoProvision = false` — `config.warnings` при normal-user + рекомендация префикса гейта.

**`nixTrust` удалён как опция, но НЕ как wiring:** ресёрч по ходу имплементации
подтвердил (nix.conf(5), `trusted-users`: «ability … to import unsigned
realisations or unsigned input-addressed store objects»), что `nix copy --to
ssh://…` протокольно ТРЕБУЕТ доверия — serve-write импортирует неподписанные
локально собранные closure, что демон позволяет только trusted users. Спека 04 §B
(«allowed-users \* достаточно») была неверна. Итог: `nix.settings.trusted-users =
[ du.name ]` безусловно; опция и её BREAKING-семантика — в миграции
(`doc/migration/direct-deploy.md` §3). Остаточный риск trust (≈ root-эквивалент
для nix-команд) ограничен SSH-гейтом D10: произвольные nix-команды через ключ
невозможны, только serve/триггеры.

### D10. SSH-гейт deploy-ключа: `restrict,command=` на authorized_keys (решение пользователя)

Вместо полного ForceCommand-whitelist через sshd `Match User` — префикс опций прямо в строке authorized_keys: `restrict,command="<store-path gate>" ssh-ed25519 ...`. Gate — небольшой shell-скрипт, генерируемый модулем (store-path без пробелов — безопасно для `command="..."`), сверяющий `$SSH_ORIGINAL_COMMAND` с разрешёнными формами:

- `nix-store --serve ...` — протокол `nix copy --to ssh://`;
- `echo '<storepath>' > /var/lib/nixtache/pending-system && systemctl start nixtache-apply.service` — apply-триггер (нормализуем: gate сам принимает store-path и делает запись+start, action переключается на вызов `nixtache-apply-trigger <path>`? — нет: action остаётся как есть, gate матчит строку целиком по регулярке со capture валидного store-path; см. риск R5);
- `true` — probe (R5);
- `systemctl start systemd-sysupdate.service` — remote ab-триггер.

Отказ — с сообщением о разрешённых формах. Почему не sshd ForceCommand: authorized_keys-префикс не трогает глобальный sshd_config таргета и не конфликтует с consumer-настройками sshd; behavior идентичен. Почему не «вообще без command=»: пользователь явно выбрал гейт; `restrict`-only оставлен escape-hatch'ем.

**Escape-hatch:** опция `deployUser.sshGate` c значениями `"gate"` (дефолт) / `"restrict"` / `"none"` — при дрейфе протокола между версией action'а и версией модуля на таргете консьюмер переключает на `restrict`-only без ожидания синхронного обновления обеих сторон.

При `autoProvision = false` модуль ключом не управляет: печатает предупреждение с готовой рекомендованной строкой префикса (включая store-path гейта) для ручного вклейки.

### D8. Мелкая доводка по местам

- `timeout`: action оборачивает per-target блок (`build`+`copy`+`activate`) в `timeout ${t.timeout}m`; фикс-тест — pure-eval на формат + документация поведения.
- `sshPublicKey`: bind-mount + `LoadCredential deploy_ssh_<name>.pub` в `deploy.nix` (зеркало приватного).
- bootCounting-предупреждение: `config.warnings` в `deploy-target` при `criticalUnits != [] && !config.boot.loader.systemd-boot.bootCounting.enable` (учёт `boot.loader.systemd-boot.enable` — предупреждение только когда systemd-boot вообще применим).
- A4/A8: расширение ассертов `auto-update` (A8 остаётся в ослабленной форме «sysupdate-заглушка валидна» — спека 09 §7 поправляется, т.к. ab-provision-one может существовать без ab-image; A4 становится строгим).
- `deploy.yml`: `concurrency: { group: deploy-${{ github.ref }}, cancel-in-progress: false }`.
- `tests/runner.nix`: сценарий `system = "aarch64-linux"` → JSON несёт поле (Batch F минимум).
- `types.nix`: честное описание `timeout`; `system` — расширить enum комментарием о derivации из hostPlatform (тип не меняем).

### D11. Dry-activate через root-юнит `nixtache-apply-dry.service` (добавлено в скоуп по итогам apply)

Найдено при имплементации: dry-ветка action'а (`nixos-rebuild dry-activate --target-host --use-remote-sudo`) требует sudo на цели — в V2 его нет (и гейт форму не пропустит), т.е. PR-предпросмотр сломан. Решение — та же V2-механика, что и switch:

- **Юнит** (apply.nix): root-oneshot — читает ОТДЕЛЬНЫЙ pointer `/var/lib/nixtache/pending-dry` (не `pending-system`, чтобы dry- и switch-триггеры не конфликтовали), выполняет `"$P"/bin/switch-to-configuration dry-activate`, удаляет pointer. Отдельный юнит, а не флаг в `nixtache-apply.service`, потому что polkit авторизует ровно `start` конкретных юнитов — сухой предпросмотр не должен делить «слишком опасный» юнит с активацией.
- **Polkit**: правило `49-nixtache-deploy.rules` расширяется на `nixtache-apply-dry.service` (verb=start, тот же файл правила — юниты-близнецы).
- **Гейт** (D10): новая разрешённая форма `echo '<storepath>' > /var/lib/nixtache/pending-dry && systemctl start nixtache-apply-dry.service` — regex зеркален switch-триггеру (валидация `/nix/store/…`).
- **Action**: dry-ветка = build + `nix copy --to` + pending-dry + триггер; `nixos-rebuild`/`--use-remote-sudo` исчезают из action полностью.
- **Тесты**: pure-eval (юнит/polkit/гейт-текст), локальный прогон gate-скрипта, VM `ab-deploy` RUN 1 переключается на реальную dry-ветку (fakeNixosRebuild-стаб удаляется) с ассертами нулевой мутации.

### D12. VM-матрица компрессий 08-A2/A3/A4/A5 (добавлено в скоуп)

Параметризация `tests/ab-deploy-e2e.nix` атрибутом компрессии (fixture уже принимает `storeCompression`): A2 = zstd-19 (дефолт, уже покрыт базовым прогоном), A3 = erofs, A4 = none, A5 = slotSize="25%" (проценты через deploy-путь). Каждый вариант — отдельный ключ `vmTests.x86_64-linux.ab-deploy-e2e-<variant>` (QEMU-тяжёлые, не в checks). Билд-уровень компрессий уже покрыт `ab-compression-vm` (K1–K4) — эти прогоны закрывают именно deploy-путь.

### D13. Переименование OTA/live-суит (добавлено в скоуп)

`ab-deploy-e2e` → `ab-ota-e2e`, `ab-anywhere-vm` → `ab-ota-anywhere-vm`, `ab-deploy-verify-vm` → `ab-ota-verify-vm` (все три — OTA-путь; `ab-deploy` остаётся live). Синхронно: ключи `flake.nix` vmTests, заголовки файлов, упоминания в README/AGENTS/doc/specs. Отдельным косметическим коммитом ПОСЛЕ D12 (иначе конфликт путей в прогоне матрицы). Live-имена не трогаем: `ab-deploy`/`ab-deploy-self-vm` уже однозначны.

### D9. Документация: четыре пласта1. **README/AGENTS** — переписать секции экспорта (6 модулей, 5 workflows, 7 actions, checks/vmTests, store.mode, deploy); вычистить HAS_SANDBOX_CAP→SANDBOX_OK, дефолт `enableSandbox = false` везде, «9 сценариев»→актуальные числа не хардкодим (формулировка без чисел).
2. **optionsMarkdown** — eval со всеми модулями (`modules = [ runner deploy-target ab-image auto-update overlay-nix ]`, `optionPrefixes services.nixtache` + явная добавка overlay-опций вне префикса, если они не под `services.nixtache.*` — при необходимости префикс-фильтр расширяется).
3. **ci.yml** — цикл по всем checks-суитам с печатью `.report`; чистка заголовков «intentionally red» (flake.nix:62-67, заголовки ab-contract/auto-update/runner-store-mode-vm/overlay-nix-vm).
4. **Спек-корпус** — back-patch: 0001 (§1/§8.3 → auto-update модуль; §9.3 без sudo; sandbox-раздел → sandbox-probe), 01 (JSON-шейп + enable/extraOptions + wiring `mkIf`), 08 (≥2.19, overlay-дизайн по TEST-SPECS §11.4, убрать dd-псевдокод), 04/05 (pointer удаляется всегда — D2), 09 (A8 ослабленная форма), README direct-deploy-директории — актуальные статусы; `doc/drafts/` для migration-plan и superseded-материалов; новый `doc/migration/direct-deploy.md` — план миграции консьюмеров.

## Risks / Trade-offs

- [Смена uid deploy-user при переходе на системный диапазон] → безболезненно: учётка не владеет файлами вне `/var/lib/nixtache` (группа); задокументировать в миграции; при странностях — удалить/пересоздать пользователя.
- [Удаление `nixTrust` ломает eval консьюмеров, полагавшихся на него] → осознанный BREAKING, в миграции: заменить на собственный `nix.settings.trusted-users`, если действительно нужен.
- [Маскирование sysupdate (D6) можно забыть снять] → лог provisioning'а обязан печатать точную команду unmask; предупреждение в journal при каждом старте, пока замаскирован.
- [RebootEnable=true на удалённых таргетах = незапланированные ребуты] → поведение соответствует спеке 06; в миграции явно указать, кому ставить `false`.
- [Контрактный тест на bash-фрагменте action'я хрупок к переформатированию YAML] → извлечение `run:`-блока уже обкатано в ab-deploy-суитах; тест ассертит наличие всех читаемых ключей в JSON (это главное).
- [Отложенные VM-тесты R4/RO6/N2/AU-F5 остаются дырами покрытия] → зафиксированы в tasks как опциональные; риск повторного дрейфа снижает контрактный тест D1.
- [R8: `switch-to-configuration dry-activate` мутирует что-то незаметно] → сценарий 2.10 ассертит неизменность профиля/`/run/current-system`/`pending-system` и потребление `pending-dry`; при обнаружении мутаций — fallback на `nix store diff-closures` в action'е.
- [R9: dry-юнит и гейт дрейфят по формам (как switch-триггер)] → та же связка гарантией: pure-eval текст-ассерты + локальный прогон gate + VM RUN 1 реальной dry-веткой.
- [R5: гейт матчит строку apply-триггера регуляркой — дрейф формата команды в action'е ломает деплой] → отказ гейта громкий (деплой падает с явным сообщением, не молча); escape-hatch `sshGate = "restrict"`; позитивные/негативные тесты гейта обязательны (tasks 2.5–2.7).
- [R6: `nixos-rebuild dry-activate --target-host` требует sudo и не сводится к формам гейта] → решено D11: dry-ветка переведена на root-юнит `nixtache-apply-dry.service` + собственную форму в гейте; `nixos-rebuild` покидает action; задачи 2.8–2.10.
- [R7: `restrict` запрещает pty — если какой-то шаг action'а запросит `-t`, он упадёт] → BatchMode-протокол деплоя pty не использует; негативный тест на forwarding уже покрывает семантику restrict.

## Migration Plan

1. Мерж этого ченджа → bump nixtache в consumer → `nix flake check` consumer'а ловит BREAKING (`nixTrust`, системный uid) → правки по `doc/migration/direct-deploy.md`.
2. Rollback: git revert + возврат input'а; состояние машин (profile/слоты) этим ченджем не мигрируется.
3. После деплоя фиксов B1/B2 — прогон одного live-деплоя на desktop-таргете (PR → dry-activate → merge → switch) как smoke.

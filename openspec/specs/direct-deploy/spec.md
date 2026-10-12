# direct-deploy Specification

## Purpose

Дельта-требования к direct-deploy (карта целей → action/workflow → apply-юнит → ab-image/OTA → auto-update): багфиксы контракта, обнаруженные аудитом спек `doc/archive/specs/0001-direct-deploy.md` и `doc/archive/specs/direct-deploy/*` против кода, и доводка поведения до заявленных спек 01–09.

## Requirements

### Requirement: Полная сериализация карты целей в env

Runner-модуль MUST сериализовать в `NIXTACHE_DEPLOY_TARGETS` все поля, которые читает action `deploy-target`: помимо `{name, host, sshUser, sshPort, method, system, tags, timeout, hasKey}` — также `enable` и `extraOptions`. Отсутствие ключа в JSON MUST интерпретироваться action'ом как значение по умолчанию, а не как «выключено»: фильтр `enable` срабатывает только при явном `"enable": false`.

#### Scenario: Таргет с enable=true деплоится через env, сгенерированный модулем

- **WHEN** модуль сконфигурирован с `deploy.targets.<name>.enable = true` (дефолт) и заданным `sshPrivateKey`, и action `deploy-target` получает `NIXTACHE_DEPLOY_TARGETS` из `runner.envs` реального модуля
- **THEN** таргет НЕ скипается на фильтре enable и доходит до probe/activate

#### Scenario: Явный enable=false скипается с предупреждением

- **WHEN** в env JSON для таргета стоит `"enable": false`
- **THEN** action выводит `skip: <name> enable=false` и продолжает обработку остальных таргетов (CI не падает)

#### Scenario: Контрактный тест модуль→action

- **WHEN** запускается контрактный тест, который вычисляет env через eval реального runner-модуля и прогоняет по нему фильтры action'а (no-entry / no-key / enable=false / probe)
- **THEN** состав JSON, сгенерированного модулем, удовлетворяет всем ключам, читаемым action'ом (включая `enable` и `extraOptions`), и фильтры ведут себя как в сценариях выше

### Requirement: Tier-1 rollback реактивирует предыдущую конфигурацию

`nixtache-apply.service` при провале probe `criticalUnits` MUST откатывать систему к pre-apply closure: `nix-env --set <prev>` И активация `<prev>/bin/switch-to-configuration switch`. Использование `/run/current-system/bin/switch-to-configuration` для отката недопустимо (после успешного switch он указывает на новый, сломанный closure).

#### Scenario: Сломавший criticalUnits switch откатывается без ребута

- **WHEN** apply-юнит применил новую конфигурацию, probe `criticalUnits` не прошёл в окне `healthCheckTimeout`
- **THEN** живая система возвращается на pre-apply closure (юниты перезапущены из старого closure), apply-юнит завершается с ненулевым кодом, CI-джоба краснеет

### Requirement: Удалённые ab-таргеты перезагружаются после обновления

Для таргетов, деплоемых по `method = "ab-image"` через SSH (не local-self), конфигурация `systemd.sysupdate` MUST устанавливать `RebootEnable = yes` на transfer'ах; для local-self (деплоер на самом хосте) — `RebootEnable = no` (cutover по idle-gating, без самоубийства джобы).

#### Scenario: Удалённый таргет активирует новый слот

- **WHEN** CI записал через sysupdate новый образ в неактивный слот удалённого ab-таргета
- **THEN** таргет перезагружается и грузится в новый слот без ручного вмешательства

### Requirement: Дефолтные метки A/B-слотов

`ab.partitions.slot_a.label` / `slot_b.label` MUST иметь дефолты `nix-store_1` / `_empty` (спека 08 §4). Созданные provisioning-скриптом GPT-партиции MUST иметь имена, соответствующие регулярному выражению stateless-детекции, даже если потребитель не задал labels явно.

#### Scenario: Provisioning без явных labels идемпотентен

- **WHEN** потребитель включил `ab.partitions` не задавая `slot_a.label`/`slot_b.label`, и provisioning отработал дважды
- **THEN** оба прогона находят уже созданные слоты по меткам (второй прогон — no-op), повторных партиций не появляется

### Requirement: Флаг gating-юнита поглощается только при успехе

`nixtache-ab-apply.service` MUST удалять флаг-файл `ab-pending` только после успешного `systemctl start systemd-sysupdate.service`. При падении старта sysupdate флаг MUST оставаться, чтобы следующее срабатывание path-юнита повторило попытку.

#### Scenario: Неудачный старт sysupdate не теряет сигнал

- **WHEN** gating-юнит не смог запустить `systemd-sysupdate.service` (например, юнит замаскирован)
- **THEN** `ab-pending` сохраняется и попытка повторяется при следующем срабатывании path-триггера

### Requirement: Конфликт размеров слотов останавливает обновления

При `onSizeMismatch = "error"` и несовпадении размеров существующих слотов с конфигурацией, provisioning MUST выводить причину и переводить `systemd-sysupdate.service` в остановленное/замаскированное состояние до ручного разрешения (unmask + повторный provisioning). Тихий `exit 0` недопустим.

#### Scenario: Size-mismatch останавливает автообновление

- **WHEN** на диске слоты не того размера, а `onSizeMismatch = "error"`
- **THEN** provisioning сообщает об ошибоке, `systemd-sysupdate` не выполняет обновления до ручного вмешательства, сервис-юнит provisioning завершается с ошибкой

### Requirement: Per-target таймаут соблюдается

Action `deploy-target` MUST ограничивать build+copy+активацию каждого таргета значением `timeout` (минуты) из карты; превышение — неудача таргета (джоба краснеет), остальные таргеты продолжают обрабатываться.

#### Scenario: Зависший таргет не блокирует пайплайн навсегда

- **WHEN** активация таргета занимает дольше `timeout` минут
- **THEN** обработка таргета прерывается по таймауту с ошибкой в логе, пайплайн завершается ненулевым кодом после обработки остальных таргетов

### Requirement: Публичный deploy-ключ доступен джобе

Если задан `deploy.targets.<name>.sshPublicKey`, модуль MUST монтировать его в контейнер и выставлять как `LoadCredential deploy_ssh_<name>.pub` (аналогично приватному ключу), а не оставлять опцию мёртвой.

#### Scenario: Публичный ключ читается из credentials-директории

- **WHEN** таргет сконфигурирован с `sshPublicKey` и джоба action'а запущена
- **THEN** файл `$CREDENTIALS_DIRECTORY/deploy_ssh_<name>.pub` существует и содержит указанный ключ

### Requirement: Предупреждение о выключенном boot counting

Приёмный модуль `deploy-target` MUST выдавать eval-предупреждение, когда `criticalUnits` непуст, а `boot.loader.systemd-boot.bootCounting.enable` не включён (Tier-0 без bootCounting не даёт отката generation).

#### Scenario: Конфиг с probe-юнитами без bootCounting предупреждает

- **WHEN** таргет задаёт `criticalUnits = [ ... ]` и не включает bootCounting
- **THEN** при eval конфигурации выводится предупреждение, связывающее оба факта

### Requirement: Ассерты auto-update для OTA-таргетов

Модуль `auto-update` MUST ассертить (спека 09 §7): A4 — при OTA-пути (`method = "auto"` с ab-таргетом, либо явный `method = "ab-image"`) конфигурация таргета содержит разрешаемый источник образов (`deploy-target.ab-image.enable` или `deploy-target.ab.partitions.source`); A8 — при явном `method = "ab-image"` на таргете отсутствует и ab-image, и ab-provision, и `systemd.sysupdate` — eval падает с понятным сообщением.

#### Scenario: Явный ab-image без OTA-модулей падает на eval

- **WHEN** `services.nixtache.auto-update.method = "ab-image"` и на машине нет ни ab-image, ни ab-provision, ни включённого systemd-sysupdate
- **THEN** eval завершается ошибкой с сообщением о неподходящей цели для OTA-пути

#### Scenario: ab-путь без источника образов падает на eval

- **WHEN** auto-update выбран ab-путь (auto-детект или явно), но ни `ab-image.enable`, ни `ab.partitions.source` не определены
- **THEN** eval завершается ошибкой с сообщением о неразрешимом источнике образов

### Requirement: Сериализация deploy-воркфлоу

`deploy.yml` MUST объявлять `concurrency.group`, уникальный для ветки/репозитория вызова, с `cancel-in-progress: false` — параллельные запуски деплоя по одной ветке становятся в очередь, а не конкурируют.

#### Scenario: Параллельные деплои одной ветки не конкурируют

- **WHEN** два деплой-рана одной ветки активны одновременно
- **THEN** второй ожидает завершения первого (очередь), ни один не отменяется автоматически

### Requirement: Dry-activate выполняется root-юнитом

Режим `dry-activate` (PR-предпросмотр, дифф без мутации) MUST реализовываться той же V2-механикой, что и `switch`, — без `nixos-rebuild` и без sudo: action копирует closure (`nix copy --to`), пишет pointer в `/var/lib/nixtache/pending-dry` и триггерит polkit'ом root-юнит `nixtache-apply-dry.service`, который выполняет `<closure>/bin/switch-to-configuration dry-activate` и удаляет pointer. На цели MUST происходить ровно ноль мутаций: профиль системы, pointer-файлы активации и `/run/current-system` не изменяются.

#### Scenario: PR-ран показывает дифф и не мутирует цель

- **WHEN** action работает в режиме `dry-activate` на таргете
- **THEN** юнит `nixtache-apply-dry.service` выводит дифф `switch-to-configuration dry-activate`, завершается успехом; системный профиль, `/run/current-system` и `pending-system` не тронуты, `pending-dry` потреблён

#### Scenario: Dry-триггер авторизуется polkit start-only

- **WHEN** deploy-пользователь выполняет `systemctl start nixtache-apply-dry.service`
- **THEN** polkit авторизует ровно `verb=start` этого юнита (наряду с `nixtache-apply.service`); stop/restart и прочие юниты отвергаются

#### Scenario: Гейт пропускает dry-триггер

- **WHEN** SSH-гейт (`sshGate = "gate"`) получает команду `echo '<storepath>' > /var/lib/nixtache/pending-dry && systemctl start nixtache-apply-dry.service` с валидным store-path
- **THEN** команда разрешается; та же форма с невалидным путём — отвергается

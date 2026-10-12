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

### Requirement: Pre-copy target disk-space check

The live deploy path SHALL query the target's free space on the store
filesystem through the deploy SSH channel and refuse the deployment before
any closure data is pushed when the target cannot hold it. The check is
two-stage, driven by the per-target preset
`services.nixtache.runner.deploy.targets.<name>.minFreeBytes` (default
5 GiB, serialized into `NIXTACHE_DEPLOY_TARGETS`):

1. **Pre-build**: free space below the preset fails the target immediately
   (no build, no copy).
2. **Post-build**: the deployment need is estimated as the narSize sum of
   the closure paths missing on the target × 1.1 + preset (conservative
   fallback when the remote store inventory fails: full closure size × 1.1
   + preset); free space below the need fails the target before `nix copy`.

A preset of `0` SHALL disable the pre-copy check entirely (no free-space
query is issued). Refusals SHALL be actionable errors naming the target,
available space, and required space — and SHALL NOT trigger
`nixtache-apply.service`. Per-target failures SHALL NOT abort the loop over
the remaining targets; the job SHALL fail at the end if any target errored.

#### Scenario: Nearly-full target fails before the build

- **WHEN** the target's free store space is below its preset
- **THEN** the target's deploy step errors naming target, available bytes
  and the preset — without building or copying anything

#### Scenario: Full-disk target fails before the copy

- **WHEN** the deploy action targets a machine whose store filesystem has
  less free space than the deployment requires
- **THEN** the target's deploy step exits with a disk-space error naming
  target, available and required bytes; no `nix copy` of the closure runs
  and `nixtache-apply.service` is not triggered

#### Scenario: Healthy target proceeds to activation

- **WHEN** the target's free space is sufficient for the deployment
- **THEN** the pre-copy check passes without side effects and the deploy
  continues (copy, pointer, apply trigger) as before

#### Scenario: One bad target does not starve the matrix

- **WHEN** one target fails its deploy (low disk, copy/apply error,
  timeout) while others are healthy
- **THEN** the failing target records a per-target `::error::`, the
  remaining targets deploy normally, and the job fails at the end naming
  the failed targets

#### Scenario: Protocol-drift target is skipped, job stays green

- **WHEN** the free-space query is rejected by the target's SSH gate (a
  pre-change gate during the two-phase rollout) or its answer is
  unparseable
- **THEN** the target is skipped with a per-target `::warning::` naming the
  `sshGate = "restrict"` transition hatch, and the drift alone does NOT
  fail the job

#### Scenario: Free-space query is read-only

- **WHEN** the deploy action queries the target's free space
- **THEN** the query runs through the gated deploy channel, mutates nothing
  on the target, and is rejected if its form deviates from the whitelisted
  command (see the deploy-user gate requirement)

#### Scenario: Pre-copy check disabled

- **WHEN** a target's deploy-map entry sets `minFreeBytes = 0`
- **THEN** no free-space query is issued for it and the deploy proceeds
  directly to build + copy

### Requirement: Apply-unit low-disk guard

`nixtache-apply.service` SHALL verify that free space on the store
filesystem is at least `services.nixtache.deploy-target.minFreeBytes` before
mutating the system profile. When below the threshold, the unit SHALL exit
non-zero with a message naming the deficit and recommending garbage
collection, while the system profile, `/run/current-system`, and the staged
closure remain untouched (nothing was activated, so no rollback runs). A
value of `0` SHALL disable the guard.

#### Scenario: Activation refused on a nearly-full target

- **WHEN** `nixtache-apply.service` starts with free space below
  `minFreeBytes`
- **THEN** the unit fails with a disk-space message; the previously active
  generation stays active, the pointer file is consumed, and the next deploy
  attempt after freeing space succeeds without recovery steps

#### Scenario: Guard is inert on a healthy target

- **WHEN** free space is at or above `minFreeBytes`
- **THEN** activation proceeds (profile set, switch, criticalUnits probe)
  exactly as before the guard existed

#### Scenario: Guard disabled

- **WHEN** `services.nixtache.deploy-target.minFreeBytes = 0`
- **THEN** the apply unit performs no free-space check at all

### Requirement: Deploy SSH does not depend on the job HOME

All SSH invocations the deploy action makes (probe, copy, pointer/trigger)
SHALL pin `UserKnownHostsFile` to a workspace-local path instead of relying
on the job environment's `HOME`, so host-key handling works in HOME-less
runner environments and target host keys have a stable per-job location.

#### Scenario: HOME-less runner job deploys without warnings

- **WHEN** the deploy action runs in a job environment with `HOME` unset
- **THEN** no `Could not create directory '/.ssh'` warnings appear and SSH
  host-key verification uses the workspace `known_hosts` file

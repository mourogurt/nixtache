# deploy-user Specification

## Purpose

Провижининг deploy-пользователя на целевой машине (приёмный модуль `deploy-target`): выделенная системная учётная запись только для SSH-активации, невидимая в графических экранах входа и не расширяющая привилегии.

## Requirements

### Requirement: Deploy-пользователь — системная учётная запись

При `deployUser.autoProvision = true` модуль MUST создавать пользователя как **системного**: `isSystemUser = true`, uid из системного диапазона (< 1000), без `isNormalUser`, без создания домашней директории в `/home`. Пользователь MUST NOT отображаться в графических экранах входа (SDDM/Plasma и т.п.), оставаясь пригодным для SSH-входа по ключу и запуска команд активации (`nix copy`, запись pointer, `systemctl start` по polkit).

#### Scenario: Deploy-пользователь не виден в SDDM

- **WHEN** на таргете включён SDDM (Plasma) и модуль провижинит deploy-пользователя
- **THEN** учётная запись отсутствует в списке пользователей экрана входа (системный uid, не normal user)

#### Scenario: SSH-активация работает с системной учётной записью

- **WHEN** deployer подключается к таргету по SSH ключом deploy-пользователя
- **THEN** вход выполняется, а команды `nix copy`, записи pointer и `systemctl start nixtache-apply.service` (polkit) доступны

#### Scenario: Конфигурация с deploy-user не проходит как normal user

- **WHEN** выполняется eval конфигурации таргета с `autoProvision = true`
- **THEN** `users.users.<name>.isNormalUser` не установлен (false), `isSystemUser = true`, uid выдан из системного диапазона

### Requirement: Минимальные привилегии deploy-пользователя

Deploy-пользователь MUST быть ограничен SSH-входом по ключу, доступом к nix-daemon, записью pointer через `nixtache-deploy` и start-only polkit для apply/dry (+ A/B-триггеры при ab). Он MUST NOT входить в `wheel` или иметь sudo/doas/run0. Безусловное членство в `trusted-users` необходимо для serve-write.

#### Scenario: Провижиненный пользователь не привилегирован

- **WHEN** модуль провижинит deploy-пользователя с дефолтами
- **THEN** пользователь состоит только в группе `nixtache-deploy` (+ безусловный trusted-users для nix-daemon), отсутствует в `wheel`, не имеет sudo/doas/run0

### Requirement: Ручное управление пользователем ассертится

При `deployUser.autoProvision = false` модуль MUST ассертить существование `users.users.<name>` (eval-ошибка с понятным сообщением при отсутствии) и всё равно добавлять пользователя в группу `nixtache-deploy` и генерировать polkit-правило под его имя. Потребитель, провижинящий пользователя вручную, SHOULD сам создавать его системным (uid < 1000); модуль MUST выдавать предупреждение, если ручной пользователь оказался normal user (видимым в DM).

#### Scenario: Отсутствующий ручной пользователь падает на eval

- **WHEN** `autoProvision = false` и `users.users.<name>` не объявлен
- **THEN** eval завершается ошибкой, указывающей имя отсутствующего deploy-пользователя

#### Scenario: Ручной normal user предупреждает

- **WHEN** `autoProvision = false`, пользователь существует, но `isNormalUser = true`
- **THEN** eval выводит предупреждение о видимости учётной записи в экранах входа

### Requirement: SSH-сессия deploy-ключа ограничена гейтом

При `autoProvision = true` модуль MUST ограничивать deploy-ключ префиксом `restrict,command=<gate>`. Gate MUST принимать только точные валидированные команды протокола из сценариев, включая serve без shell-chaining и pointer-формы с проверкой store-path. Произвольные команды и неутверждённые chaining/redirection, pty/X11/agent/port-forwarding MUST отвергаться с понятным сообщением. Опция `restrict`-only MUST отключать gate для дрейфа протокола.

#### Scenario: Port forwarding запрещён

- **WHEN** держатель ключа открывает SSH-соединение с `-L`/`-R`/`-D` (туннелирование)
- **THEN** соединение отвергается опцией `restrict` — туннель не устанавливается

#### Scenario: Произвольная команда отвергается гейтом

- **WHEN** держатель ключа пытается выполнить команду, не входящую в рабочий протокол деплоя (например, запуск shell или чтение произвольных файлов)
- **THEN** gate завершается с отказом и сообщением о разрешённых формах команд; на цели не выполняется ничего

#### Scenario: Рабочий протокол деплоя проходит без изменений

- **WHEN** action выполняет probe, `nix copy`, apply/dry-триггеры, remote A/B-команду `systemctl start --wait systemd-sysupdate.service && systemctl start systemd-sysupdate-reboot.service` или local-self сигнал через `ab-pending` + `nixtache-ab-apply.service`
- **THEN** gate принимает эти точные формы; pointer и dry-pointer допускаются только с валидным `/nix/store/...` путём

#### Scenario: Escape-hatch на restrict-only

- **WHEN** потребитель переключает опцию гейта в режим `restrict`-only
- **THEN** authorized_keys несёт только префикс `restrict` (без `command=`), команды выполняются как прежде; eval не требует изменений в action'е

#### Scenario: Ручное управление ключом без гейта предупреждает

- **WHEN** `autoProvision = false` и потребитель управляет authorized_keys сам
- **THEN** модуль не может навязать префикс и выводит предупреждение с готовым рекомендуемым префиксом (строкой `restrict,command=...`) для ручного применения

### Requirement: Gate allows the disk-space query

The SSH gate whitelist SHALL additionally allow the exact, read-only
free-space query command issued by the deploy action's pre-copy check (an
exact-match command string reporting free space in bytes on the store
filesystem mount). The gate MUST continue to reject any variant form of the
command (extra arguments, redirections, chaining), and the query MUST NOT
grant any capability beyond reporting free space.

#### Scenario: The action's free-space query passes the gate

- **WHEN** the deploy action issues the whitelisted free-space query through
  the deploy key on a target with `sshGate = "gate"`
- **THEN** the gate executes it and returns the free-space value; nothing on
  the target is modified

#### Scenario: Mutated query forms are rejected

- **WHEN** the command deviates from the exact whitelisted form (extra
  arguments, shell chaining, redirection)
- **THEN** the gate rejects it with the standard not-allowed message and
  nothing executes on the target

#### Scenario: Protocol-drift transition stays available

- **WHEN** a consumer runs a new action (which issues the query) against a
  target whose still-active generation carries a pre-change gate
- **THEN** the gate rejects the query, the action skips that target with a
  warning (the job stays green), and the consumer can temporarily set
  `sshGate = "restrict"` on the target (documented migration path) until
  both sides carry the new protocol, after which the gate is re-enabled

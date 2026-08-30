# deploy-user Specification

## Purpose

Провижининг deploy-пользователя на целевой машине (приёмный модуль `deploy-target`): выделенная системная учётная запись только для SSH-активации, невидимая в графических экранах входа и не расширяющая привилегии.

## Requirements

### Requirement: Deploy-пользователь — системная учётная запись

При `deployUser.autoProvision = true` модуль MUST создавать пользователя как **системного**: `isSystemUser = true`, uid из системного диапазона (< 1000), без `isNormalUser`, без создания домашней директории в `/home`. Пользователь MUST NOT отображаться в графических экранах входа (SDDM/Plasma и т.п.), оставаясь пригодным для SSH-входа по ключу и запуска команд активации (`nix copy`, запись pointer, `systemctl start` по polkit).

#### Scenario: Deploy-пользователь не виден в SDDM

- **WHEN** на таргете включён SDDM (Plasma) и модуль провижинит deploy-пользователя
- **THEN** учётная запись отсутствует в списке пользователей экрана входа (системный uid, не normal user)

#### Scenario: SSH-активация по-прежнему работает

- **WHEN** deployer подключается к таргету по SSH ключом deploy-пользователя
- **THEN** вход выполняется, команды `nix copy`/записи pointer/`systemctl start nixtache-apply.service` (polkit) доступны как раньше

#### Scenario: Конфигурация с deploy-user не проходит как normal user

- **WHEN** выполняется eval конфигурации таргета с `autoProvision = true`
- **THEN** `users.users.<name>.isNormalUser` не установлен (false), `isSystemUser = true`, uid выдан из системного диапазона

### Requirement: Минимальные привилегии deploy-пользователя

Deploy-пользователь MUST обладать ровно четырьмя возможностями: SSH-вход по авторизованному ключу, доступ к nix-daemon (дефолтные `allowed-users`), запись в pointer-директорию через группу `nixtache-deploy`, polkit-авторизация на `start nixtache-apply.service` и `start nixtache-apply-dry.service` (+ ab-триггеры при включённом ab). Пользователь MUST NOT входить в `wheel`, не иметь sudo/doas/run0; членство в `trusted-users` — безусловное исключение (протокольное требование serve-write, см. требование о провижининге).

#### Scenario: Опция nixTrust удалена

- **WHEN** потребитель задаёт `services.nixtache.deploy-target.deployUser.nixTrust` в конфигурации после обновления
- **THEN** eval падает с ошибкой неизвестной опции; доверие больше не управляется опцией — модуль добавляет deploy-пользователя в `nix.settings.trusted-users` безусловно (протокольное требование serve-write)

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

При `autoProvision = true` модуль MUST оформлять авторизованный ключ деплоя с префиксом `restrict,command=<gate>` в authorized_keys, где gate — генерируемый модулем скрипт, разрешающий ровно команды рабочего протокола деплоя: `nix-store --serve ...` (для `nix copy --to ssh://`), запись pointer + `systemctl start nixtache-apply.service`, запись dry-pointer + `systemctl start nixtache-apply-dry.service`, пробу соединения (`true`) и триггеры `systemctl start systemd-sysupdate.service` / `systemd-sysupdate-reboot.service` (ab-таргеты). Обе pointer-формы MUST проверять валидность store-path (`/nix/store/...`). Любая другая команда, а также pty/X11/agent/port-forwarding MUST отвергаться с понятным сообщением в лог. Модуль MUST предоставлять опцию отката: `restrict`-only (без гейта) для случаев дрейфа протокола.

#### Scenario: Port forwarding запрещён

- **WHEN** держатель ключа открывает SSH-соединение с `-L`/`-R`/`-D` (туннелирование)
- **THEN** соединение отвергается опцией `restrict` — туннель не устанавливается

#### Scenario: Произвольная команда отвергается гейтом

- **WHEN** держатель ключа пытается выполнить команду, не входящую в рабочий протокол деплоя (например, запуск shell или чтение произвольных файлов)
- **THEN** gate завершается с отказом и сообщением о разрешённых формах команд; на цели не выполняется ничего

#### Scenario: Рабочий протокол деплоя проходит без изменений

- **WHEN** action `deploy-target` выполняет probe, `nix copy --to ssh://...`, apply-триггер и dry-триггер на таргете с включённым гейтом
- **THEN** все операции завершаются успешно — gate прозрачен для протокола деплоя

#### Scenario: Escape-hatch на restrict-only

- **WHEN** потребитель переключает опцию гейта в режим `restrict`-only
- **THEN** authorized_keys несёт только префикс `restrict` (без `command=`), команды выполняются как прежде; eval не требует изменений в action'е

#### Scenario: Ручное управление ключом без гейта предупреждает

- **WHEN** `autoProvision = false` и потребитель управляет authorized_keys сам
- **THEN** модуль не может навязать префикс и выводит предупреждение с готовым рекомендуемым префиксом (строкой `restrict,command=...`) для ручного применения

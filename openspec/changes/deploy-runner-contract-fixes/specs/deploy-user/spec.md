# Spec Delta

## MODIFIED Requirements

### Requirement: Ручное управление пользователем ассертится

При `deployUser.autoProvision = false` модуль MUST ассертить существование `users.users.<name>` (eval-ошибка с понятным сообщением при отсутствии) и всё равно добавлять пользователя в группу `nixtache-deploy` и генерировать polkit-правило под его имя. Потребитель, провижинящий пользователя вручную, SHOULD сам создавать его системным (uid < 1000); модуль MUST выдавать предупреждение, если ручной пользователь оказался normal user (видимым в DM).

#### Scenario: Отсутствующий ручной пользователь падает на eval

- **WHEN** `autoProvision = false` и `users.users.<name>` не объявлен
- **THEN** eval завершается ошибкой, указывающей имя отсутствующего deploy-пользователя и предлагающей создать его или включить `autoProvision`

#### Scenario: Group membership does not fabricate the manual user

- **WHEN** the module adds a hand-managed user to `nixtache-deploy`
- **THEN** membership is added without defining `users.users.<name>` in this module, so a consumer declaration remains distinguishable from a missing user

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

#### Scenario: Serve suffixes cannot escape the protocol

- **WHEN** the command starts with an allowed serve form but appends shell syntax, such as `nix-store --serve; id`, `nix-store --serve --write && id`, or a redirection
- **THEN** the gate rejects the whole command and neither the serve process nor the appended command/redirection executes

#### Scenario: Рабочий протокол деплоя проходит без изменений

- **WHEN** action выполняет probe, `nix copy`, apply/dry-триггеры, remote A/B-команду `systemctl start --wait systemd-sysupdate.service && systemctl start systemd-sysupdate-reboot.service` или local-self сигнал через `ab-pending` + `nixtache-ab-apply.service`
- **THEN** gate принимает эти точные формы; pointer и dry-pointer допускаются только с валидным `/nix/store/...` путём

#### Scenario: Escape-hatch на restrict-only

- **WHEN** потребитель переключает опцию гейта в режим `restrict`-only
- **THEN** authorized_keys несёт только префикс `restrict` (без `command=`), команды выполняются как прежде; eval не требует изменений в action'е

#### Scenario: Ручное управление ключом без гейта предупреждает

- **WHEN** `autoProvision = false` и потребитель управляет authorized_keys сам
- **THEN** модуль не может навязать префикс и выводит предупреждение с готовым рекомендуемым префиксом (строкой `restrict,command=...`) для ручного применения

## Purpose

Документирование реализованной поверхности флейка nixtache: пользовательские доки (README/AGENTS), генерируемый reference опций, CI-отчёты и поддержание спек-корпуса `doc/specs/` в согласованном с кодом состоянии.

## ADDED Requirements

### Requirement: README документирует весь экспорт флейка

README.md MUST документировать все экспортируемые поверхности: nixosModules (`runner`, `deploy-target`, `ab-image`, `overlay-nix`, `auto-update`, `secrets`), workflows (`nix-check`, `deploy`, `update-flake`, `docs`, `ci`), actions (включая `deploy-target` и `sandbox-probe`), выходы `checks`/`vmTests` (включая правило «vmTests не запускаются в CI, только вручную на KVM-хосте»), опции `runner.deploy.targets` и `store.mode`. Раздел про sandbox MUST описывать фактический механизм: runtime-probe `sandbox-probe` → `SANDBOX_OK`, а не статический `HAS_SANDBOX_CAP`.

#### Scenario: Читатель README узнаёт о deploy-фиче

- **WHEN** читатель открывает README.md
- **THEN** находит раздел про direct-deploy (карта целей, приёмный модуль, live/ab-image, авто-update) со ссылками на спеки и указанием, с чего начать консьюмеру

#### Scenario: Список модулей в README совпадает с flake.nix

- **WHEN** flake.nix экспортирует `nixosModules.{runner,deploy-target,ab-image,overlay-nix,auto-update,secrets}`
- **THEN** README перечисляет и кратко описывает каждый из них; отсутствующих/лишних записей нет

### Requirement: AGENTS.md соответствует реальности

AGENTS.md MUST отражать текущее состояние: полный список модулей/workflows/actions, корректный дефолт `enableSandbox = false` во всех упоминаниях, описание sandbox-probe/SANDBOX_OK, отсутствие заявлений «deploy не реализован»/«checks = только runner». Внутренние противоречия (дефолт sandbox в таблице vs сниппете) недопустимы.

#### Scenario: AGENTS.md не содержит протухших фактов

- **WHEN** AGENTS.md сверяется с flake.nix и кодом модулей
- **THEN** каждое утверждение об экспортах, дефолтах и CI-поведении подтверждается кодом; секция TODO не содержит уже реализованных пунктов

### Requirement: Генерируемый reference опций покрывает все модули

`packages.optionsMarkdown`/`optionsJSON`/`optionsHTML` MUST генерироваться из eval, включающего ВСЕ nixtache-модули (весь префикс `services.nixtache.*`: runner, deploy-target, ab-image, auto-update — опции overlay-nix/store вне префикса фиксируются явно), в strict-режиме (без description — падение сборки доков).

#### Scenario: Reference содержит опции deploy-target

- **WHEN** собирается `nix build .#optionsMarkdown`
- **THEN** в reference присутствуют опции `services.nixtache.deploy-target.*`, `services.nixtache.runner.deploy.targets.*`, `services.nixtache.auto-update.*` — а не только runner

### Requirement: CI-лог показывает все тестовые суиты

`ci.yml` MUST печатать отчёты (ok/FAIL-таблицы) всех `checks.<system>`-суит, которые собирает `nix flake check`, а не только runner; заголовки файлов не должны утверждать «intentionally red»/«модуль не существует» для уже приземлившихся модулей.

#### Scenario: Отчёт по каждой суите виден в логе

- **WHEN** CI-джоба завершается
- **THEN** в логе присутствуют отдельные блоки отчётов для runner, deploy-target, ab-image, ab-existing, ab-contract, auto-update и mkDocs-суит

### Requirement: Спек-корпус синхронизирован с решениями

`doc/specs/` MUST быть приведён к состоянию «код = источник истины, зафиксированный спеками»: 0001 §1/§8.3 ссылаются на модуль auto-update как канал доставки по умолчанию (не `system.autoUpgrade`); 0001 §9.3 не упоминает sudo-фоллбек; 08 — Nix ≥ 2.19 и фактический overlay-дизайн; 01 — фактический JSON-шейп (с `enable`/`extraOptions`); статусные колонки README директории direct-deploy отражают реализованность. Superseded-черновики MUST быть перемещены в `doc/drafts/` с пометкой.

#### Scenario: Читатель 0001 не получает устаревшую модель доставки

- **WHEN** читается `doc/specs/0001-direct-deploy.md`
- **THEN** модель доставки описывает единый модуль auto-update (flake/OTA-пути) и не утверждает host-level `system.autoUpgrade` как дефолт

#### Scenario: Черновики изолированы

- **WHEN** открывается `doc/drafts/`
- **THEN** там лежат superseded-документы (migration-plan и пр.) с явной пометкой о замещении; из `doc/specs/` они убраны или оставлены как указатели

### Requirement: План миграции консьюмеров

Репозиторий MUST содержать документ миграции для консьюмеров nixtache: подключение deploy-фичи на существующем флeйке (карта, deploy-ключи, приёмный модуль, workflows-обёртки), переход на auto-update вместо `system.autoUpgrade`, BREAKING-изменения этого ченджа (удаление `deployUser.nixTrust`, системный deploy-user).

#### Scenario: Консьюмер может обновиться по документу

- **WHEN** консьюмер с предыдущей версией nixtache обновляет input и следует документу миграции
- **THEN** все BREAKING-изменения перечислены с действиями (что убрать, чем заменить), финальная конфигурация проходит `nix flake check`

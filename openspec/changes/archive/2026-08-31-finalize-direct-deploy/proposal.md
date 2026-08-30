## Why

Аудит direct-deploy (спека `doc/specs/0001-direct-deploy.md` + `doc/specs/direct-deploy/*` против кода на HEAD `1a0f937`) показал: функциональность реализована почти целиком (батчи A–E + auto-update, 7 pure-eval и 15 VM-суит), но контракт между runner-модулем и action'ом сломан в проде (деплой скипается), Tier-1 rollback не откатывает живую систему, часть спекфицированного поведения молча не реализована, а вся новая поверхность (deploy-target/ab-image/overlay-nix/auto-update, deploy.yml, sandbox-probe, vmTests) не документирована ни в README, ни в AGENTS.md. Плюс провижининг deploy-пользователя делает его обычным `isNormalUser` — он виден в SDDM/Plasma как учётка для входа.

## What Changes

**P0 — баги контракта (спека права, код — нет):**
- Сериализация карты: `enable` и `extraOptions` попадают в `NIXTACHE_DEPLOY_TARGETS` (сейчас action читает отсутствующие ключи → все таргеты скипаются); контрактный тест гоняет фильтры action'а на JSON, сгенерированном **реальным модулем**, а не рукою сварённым.
- Tier-1 rollback: повторная активация pre-apply closure через `$prev/bin/switch-to-configuration switch` (сейчас — `/run/current-system/...`, т.е. ре-активация сломанного нового конфига).
- `Transfer.RebootEnable` для удалённых ab-таргетов (сейчас не ставится вовсе — образ ставится, но не активируется до ручного ребута).
- Дефолты меток слотов `nix-store_1`/`_empty` в ab-provision (сейчас `null` → безымянные GPT-партиции, детекция не работает).
- Порядок в gating-юните: `ab-pending` удаляется только после успешного `systemctl start systemd-sysupdate`.
- `onSizeMismatch = "error"` реально останавливает sysupdate до ручного разрешения (сейчас — лог + exit 0).

**Deploy-user:**
- **BREAKING**: `deployUser.autoProvision` создаёт **системного** пользователя (`isSystemUser`, uid < 1000, без `isNormalUser`) — невидим в SDDM/Plasma; опция `deployUser.nixTrust` удаляется, доверие (trusted-users) становится безусловным — протокольное требование `nix copy --to ssh://` serve-write (nix.conf(5)), уточнение D7 по факту имплементации.
- SSH-сессия deploy-ключа ограничивается на уровне authorized_keys: префикс `restrict,command=<gate>` с минимальным гейтом (`nix-store --serve`, apply-/dry-триггеры, probe, sysupdate-триггеры); escape-hatch — опция отката на `restrict`-only. Решено вместо полного ForceCommand-whitelist через sshd (см. design D10).

**Dry-activate через root-юнит (добавлено в скоуп по итогам применения):**
- Ветка `dry-activate` в action сломана в V2 (`nixos-rebuild --use-remote-sudo` требует sudo, которого у deploy-пользователя нет). Замена: `nixtache-apply-dry.service` — root-юнит по polkit (pointer `pending-dry` → `switch-to-configuration dry-activate`, ноль мутаций), новая форма в гейте, dry-ветка action'а без `nixos-rebuild` (design D11).

**Тестовая матрица и косметика (добавлено в скоуп):**
- VM-тесты 08-A2/A3/A4/A5: параметризация deploy-e2e матрицей компрессий (squashfs+zstd-19 / erofs / без компрессии / slotSize="25%") — design D12.
- Переименование OTA/live-суит (`ab-deploy-e2e` → `ab-ota-e2e`, `ab-anywhere-vm` → `ab-ota-anywhere-vm` + ключи flake.nix/доки) отдельным косметическим коммитом — design D13.

**Доводка до спеки (мелкие пробелы):**
- Per-target `timeout` реально соблюдается action'ом; `sshPublicKey` монтируется как `deploy_ssh_<name>.pub` LoadCredential.
- Предупреждение при `criticalUnits` задан + bootCounting выключен.
- Ассерты A4 (resolvability source) и A8 в auto-update — по спеке 09 §7; concurrency-группа в `deploy.yml`.
- Pure-eval сценарий `system = "aarch64-linux"` в `tests/runner.nix` (Batch F минимум).

**Документация (отдельная задача):**
- README/AGENTS: все 6 nixosModules, 5 workflows, 7 actions, vmTests, store.mode, deploy-фича; вычистка протухших заявлений (HAS_SANDBOX_CAP → sandbox-probe/SANDBOX_OK, дефолт `enableSandbox`, «9 сценариев»).
- `optionsMarkdown`/`optionsJSON`/`optionsHTML` покрывают **все** `services.nixtache.*` модули, не только runner.
- ci.yml печатает отчёты всех checks-суит; чистка «intentionally red» комментариев.
- Back-patch спек-корпуса (0001 §1/§8.3/§9.3, 01 JSON-шейп, 08: Nix ≥ 2.19 + overlay-дизайн) и переезд superseded-бумаг в `doc/drafts/`; план миграции для консьюмеров.

## Capabilities

### New Capabilities
- `direct-deploy`: контракт карты целей, action/workflow, apply-юниты (switch + dry), ab-image/gating, auto-update — дельта-требования багфиксов и доводки до спек 01–09.
- `deploy-user`: провижининг deploy-пользователя на таргете — системный пользователь, невидимый в display manager, без sudo (trusted-users — безусловно, протокол serve-write).
- `docs`: документирование реализованной поверхности флейка — README/AGENTS, генерируемый option-reference, CI-отчёты, back-patch спек-корпуса.

### Modified Capabilities

(нет — `openspec/specs/` пуст, главных спек ещё не существует)

## Impact

- Код: `modules/runner/{deploy,types}.nix`, `modules/deploy-target/{user,apply,ab,ab-provision,options}.nix`, `modules/ab-image/default.nix`, `modules/auto-update/default.nix`, `.forgejo/actions/deploy-target/action.yml`, `.forgejo/workflows/deploy.yml`, `flake.nix` (docs-eval), `.forgejo/workflows/ci.yml`.
- Тесты: `tests/{runner,deploy-target,auto-update}.nix` (+ новый контрактный сценарий module→action), VM-суиты для gating/rollback по мере необходимости.
- **BREAKING** для консьюмеров: удаление `deployUser.nixTrust`; смена `isNormalUser` → `isSystemUser` (uid меняется при следующем rebuild — ключи/файлы владельца не затрагиваются, т.к. home не используется).
- Доки: `README.md`, `AGENTS.md`, `doc/specs/**`, новый `doc/drafts/`, план миграции консьюмеров.

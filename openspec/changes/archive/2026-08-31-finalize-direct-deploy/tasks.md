## 1. P0 — баги контракта direct-deploy

- [x] 1.1 Сериализовать `enable` и `extraOptions` в `NIXTACHE_DEPLOY_TARGETS` (`modules/runner/deploy.nix`); в action'е дать safe-default `enable` (отсутствует ⇒ true). Verify: pure-eval сценарий в `tests/runner.nix` ассертит оба ключа в env JSON
- [x] 1.2 Контрактный тест модуль→action: pure-eval вычисляет env реального runner-модуля, извлекает `run:`-блок `action.yml` (механизмом ab-deploy-суит), прогоняет фильтры (no-entry / no-key / enable=false) на module-generated JSON. Verify: `nix build .#checks.x86_64-linux.runner` — новый сценарий ok
- [x] 1.3 Rollback в `nixtache-apply.service` активирует `$prev/bin/switch-to-configuration switch` вместо `/run/current-system/...` (`modules/deploy-target/apply.nix`). Verify: сценарий в `tests/deploy-target.nix` ассертит текст скрипта; VM-прогон `auto-update-vm` (AU-F4) на KVM-хосте зелёный
- [x] 1.4 `RebootEnable` в transfer'ах `modules/ab-image` (remote ⇒ yes, local-self ⇒ no, через документируемую опцию). Verify: сценарий `tests/ab-image.nix` ассертит значение в transfer-definitions для обоих режимов
- [x] 1.5 Дефолты `slot_a.label = "nix-store_1"`, `slot_b.label = "_empty"` (`modules/deploy-target/ab-provision.nix`). Verify: сценарий `tests/ab-contract.nix` ассертит дефолты; `ab-provision-vm` P2 прогоняется без явных labels
- [x] 1.6 Gating: `rm -f ab-pending` только после успешного `systemctl start systemd-sysupdate` (`modules/deploy-target/ab.nix`). Verify: расширение `tests/ab-deploy-self-vm.nix` — замаскированный sysupdate ⇒ флаг сохраняется
- [x] 1.7 `onSizeMismatch = "error"`: лог + `systemctl mask systemd-sysupdate.service` + `exit 1` (`ab-provision.nix`). Verify: S1-сценарий `ab-provision-vm` дополняется ассертом is-masked
- [x] 1.8 Прогнать все pure-eval суиты: `nix flake check --show-trace --all-systems` зелёный; отчёты `nix build .#checks.x86_64-linux.{runner,deploy-target,ab-image,ab-contract}` без FAIL

## 2. Deploy-user (system user + SDDM)

- [x] 2.1 `autoProvision = true` → `isSystemUser = true`, uid < 1000, без `isNormalUser`/`createHome` (`modules/deploy-target/user.nix`). Verify: сценарий `tests/deploy-target.nix` ассертит isSystemUser/isNormalUser; VM-проверка `id -u < deploy-user` < 1000
- [x] 2.2 **BREAKING**: удалить опцию `deployUser.nixTrust` и wiring в `trusted-users` (`options.nix`, `user.nix`). Verify: сценарий, задающий nixTrust, падает на eval с unknown option
- [x] 2.3 `autoProvision = false` + ручной normal user → `config.warnings` о видимости в DM. Verify: сценарий `tests/deploy-target.nix` ловит предупреждение
- [x] 2.4 VM-сценарий SDDM-невидимости: в подходящей VM-суите (или новой лёгкой) ассерт, что deploy-user отсутствует в списке учёток с uid ≥ 1000 (достаточно `getent passwd`-фильтра — SDDM показывает uid ≥ 1000). Verify: VM-суита зелёная на KVM-хосте
- [x] 2.5 SSH-гейт (design D10): gate-скрипт (разрешает `nix-store --serve`, apply-триггер с capture store-path, `true`, `systemctl start systemd-sysupdate`) + префикс `restrict,command=<gate>` в authorized_keys при `autoProvision = true`; опция `deployUser.sshGate = "gate" | "restrict" | "none"` (дефолт `"gate"`); при `autoProvision = false` — warning с рекомендованной строкой префикса. Verify: сценарии в `tests/deploy-target.nix` (префикс в authorized_keys, дефолт/escape-hatch опции)
- [x] 2.6 VM-тесты гейта: позитив — probe / `nix copy --to ssh://` / apply-триггер проходят; негатив — произвольная команда и port forwarding (`ssh -L`) отвергаются. Verify: VM-суита (расширение ab-deploy или новая лёгкая) зелёная на KVM-хосте
- [x] 2.7 Синхронизировать action `deploy-target` с гейтом: убедиться, что все SSH-команды action'а соответствуют разрешённым формам (включая quoting `echo '$P' > ...`). Verify: контрактный тест 1.2 прогоняется против таргета с гейтом (VM) без отказов
- [x] 2.8 `nixtache-apply-dry.service` в `modules/deploy-target/apply.nix` (design D11): root-юнит oneshot — читает pointer `/var/lib/nixtache/pending-dry` → `"$P"/bin/switch-to-configuration dry-activate` (дифф, БЕЗ мутации) → удаляет pointer; polkit-правило `49-nixtache-deploy.rules` расширяется на `start nixtache-apply-dry.service` (verb=start только). Заменяет сломанную ветку `nixos-rebuild dry-activate --use-remote-sudo` (требует sudo, которого нет в V2). Verify: сценарии `tests/deploy-target.nix` — юнит wired, polkit имена оба юнита
- [x] 2.9 Гейт (D10/D11): разрешить форму `echo '<storepath>' > /var/lib/nixtache/pending-dry && systemctl start nixtache-apply-dry.service` (regex с capture валидного store-path, как у switch-триггера). Verify: локальный прогон gate-скрипта (как в 2.5) + сценарий `tests/deploy-target.nix` на текст гейта
- [x] 2.10 Action `deploy-target`: dry-activate ветка → build toplevel + `nix copy --to` + pointer `pending-dry` + `systemctl start nixtache-apply-dry.service` (никакого `nixos-rebuild`/`--use-remote-sudo`); из `tests/ab-deploy.nix` удалить fakeNixosRebuild-стаб — RUN 1 гоняет реальную dry-ветку. Verify: VM `ab-deploy` — RUN 1 показывает дифф, профиль/pointer/таргет не мутированы, pending-dry consumed

## 3. Доводка до спеки

- [x] 3.1 Per-target `timeout`: action оборачивает build+copy+activate в `timeout ${t.timeout}m` (ненулевой exit, остальные таргеты продолжаются). Verify: pure-eval контракт-сценарий на формат + ручной smoke с timeout=1
- [x] 3.2 `sshPublicKey` → bind-mount + `LoadCredential deploy_ssh_<name>.pub` (`deploy.nix`). Verify: сценарий `tests/runner.nix` ассертит mount+credential при заданном pubkey
- [x] 3.3 `config.warnings` в deploy-target: `criticalUnits != []` + bootCounting выключен (+ systemd-boot применим). Verify: сценарий `tests/deploy-target.nix` ловит warning
- [x] 3.4 Ассерты auto-update: A4 строгий (ab-путь ⇒ есть `ab-image.enable` или `ab.partitions.source`), A8 в ослабленной форме + правка 09 §7. Verify: сценарии в `tests/auto-update.nix` (AU-11B/AU-13 расширить)
- [x] 3.5 `concurrency.group` в `.forgejo/workflows/deploy.yml` (`cancel-in-progress: false`). Verify: `python3 -c "yaml.safe_load(...)"` + наличие ключа
- [x] 3.6 Сценарий `system = "aarch64-linux"` в `tests/runner.nix` (поле в JSON, без buildHost). Verify: `nix build .#checks.x86_64-linux.runner` ok
- [x] 3.7 Честные описания опций: `timeout` (реально соблюдается), `system` (derivация). Verify: `nix build .#optionsMarkdown` — strict-режим зелёный

## 4. Документация (отдельная задача)

- [x] 4.1 README: секции для deploy-target / ab-image / overlay-nix / auto-update / deploy.yml / sandbox-probe / store.mode / vmTests-правило; sandbox-раздел переписать на runtime-probe `SANDBOX_OK`. Verify: сверка списка модулей README ↔ flake.nix nixosModules без расхождений
- [x] 4.2 AGENTS.md: экспорты (6 модулей, 5 workflows, 7 actions, vmTests), `enableSandbox = false` консистентно, вычистить «deploy — отдельная задача» из TODO. Verify: каждое факт-утверждение AGENTS.md подтверждается кодом (выборочная сверка)
- [x] 4.3 `optionsMarkdown`/`optionsJSON`/`optionsHTML` из eval всех модулей (`services.nixtache.*` целиком). Verify: `nix build .#optionsMarkdown` содержит секции deploy-target/auto-update/ab-image
- [x] 4.4 `ci.yml`: печать отчётов всех checks-суит циклом. Verify: лог CI (или локальная эмуляция шага) содержит блоки всех 7 суит
- [x] 4.5 Убрать «intentionally red»/«модуль не существует» заголовки: flake.nix (комментарии ab-contract), tests/ab-contract.nix, tests/auto-update.nix, tests/runner-store-mode-vm.nix, tests/overlay-nix-vm.nix, ci.yml-заголовок про отсутствие nixosConfigurations (учесть abtest-remote). Verify: `rg -i "intentionally red|does NOT exist yet|FAILS NOW" tests/ flake.nix .forgejo/` пусто

## 5. Спек-корпус и миграция

- [x] 5.1 Back-patch 0001: §1/§8.3 — модель доставки через модуль auto-update (не system.autoUpgrade); §9.3 — убрать sudo-фоллбек (root на цели); sandbox-тексты → sandbox-probe/SANDBOX_OK. Verify: в 0001 нет упоминаний autoUpgrade-дефолта и HAS_SANDBOX_CAP как рабочего механизма
- [x] 5.2 Back-patch 01: JSON-шейп с `enable`/`extraOptions`; wiring-сниппет соответствует факту (env ставится всегда). Verify: шейп в 01 == сериализация deploy.nix
- [x] 5.3 Back-patch 08: Nix ≥ 2.19 (все вхождения), overlay-дизайн по фактической реализации (overmount `/nix/store`, системный daemon, `lower-store=local`), убрать dd-псевдокод slot A. Verify: `rg "2\.35|/mnt/nix-overlay|dd if=" doc/specs/0008* doc/specs/direct-deploy/08*` пусто
- [x] 5.4 Back-patch 04/05 (pointer удаляется и при провале — анти-retry, D2) и 09 (A8 ослабленная форма); актуализировать статусные колонки README директории direct-deploy. Verify: статусы соответствуют реализованности (06/08/09 — nixtache ✅)
- [x] 5.5 Создать `doc/drafts/`, перенести superseded-бумаги (migration-plan.md и др.) с пометками-указателями. Verify: `doc/drafts/` существует, битых ссылок нет (`rg "migration-plan" doc/ README.md AGENTS.md` ведёт на новые пути)
- [x] 5.6 Написать `doc/migration/direct-deploy.md`: подключение deploy-фичи консьюмером, переход на auto-update, BREAKING этого ченджа (nixTrust, системный uid). Verify: документ покрывает все BREAKING из proposal; вычитка

## 6. Тестовая матрица и косметика (в скоупе)

- [x] 6.1 VM-тесты 08-A2/A3/A4/A5 (design D12): параметризовать `tests/ab-deploy-e2e.nix` матрицей компрессий — A2 squashfs+zstd-19, A3 erofs, A4 без компрессии, A5 slotSize="25%" через deploy-путь. Verify: `nix build .#vmTests.x86_64-linux.ab-deploy-e2e-<variant>` зелёные на KVM-хосте; ID покрыты (сводка в заголовке суиты)
- [x] 6.2 Прогон отложенных VM-суит на KVM-хосте: ab-deploy-self-vm, ab-provision-vm, auto-update-vm (полный регресс после 1.3/1.6/1.7/2.x)
- [x] 6.3 Переименование суит OTA/live (design D13, TODO-LIST item 5): `ab-deploy-e2e` → `ab-ota-e2e`, `ab-anywhere-vm` → `ab-ota-anywhere-vm` (+ ключи `flake.nix` vmTests, заголовки файлов, упоминания в README/AGENTS/doc). Отдельным косметическим коммитом после 6.1. Verify: `rg "ab-deploy-e2e|ab-anywhere-vm" flake.nix tests/ README.md AGENTS.md doc/` ведёт только на новые имена

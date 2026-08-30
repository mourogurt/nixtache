# Миграция консьюмера на direct-deploy + auto-update

Практический гайд для репозиториев, потребляющих nixtache: подключение
деплой-фичи, переход с `system.autoUpgrade` на единый модуль auto-update и
разбор BREAKING-изменений. Дизайн — `doc/specs/0001-direct-deploy.md` +
`doc/specs/direct-deploy/`; спека модуля — `09-auto-update.md`.

## 1. Подключение деплоя (с нуля)

### 1.1. Runner-хост: карта целей + ключи

В конфиг машины с `services.nixtache.runner` добавьте карту — по одной записи
на `nixosConfigurations.<name>`, до которой этот раннер может деплоить:

```nix
{ config, ... }: {
  sops.secrets.deploy-key-desktop = { sopsFile = ../../secrets/deploy-keys/desktop.ed25519; format = "binary"; };

  services.nixtache.runner.deploy.targets.desktop = {
    host          = "10.13.37.3";              # LAN/VPN-адрес цели
    sshUser       = "nixos-deploy";            # дефолт
    sshPrivateKey = config.sops.secrets.deploy-key-desktop.path;
    # method = "ab-image";                     # только для A/B-таргетов (OTA)
    # timeout = 240;                            # минут на таргет (дефолт)
  };
}
```

Карта сериализуется в job-env `NIXTACHE_DEPLOY_TARGETS` (без секретных путей),
ключи — в `LoadCredential deploy_ssh_<name>`.

### 1.2. Цель: приёмный модуль

В конфиг **каждой** машины-таргета:

```nix
{ ... }: {
  imports = [ inputs.nixtache.nixosModules.deploy-target ];

  services.nixtache.deploy-target = {
    criticalUnits = [ "wireguard-awg0.service" ];  # что считать «машина жива»
    healthCheckTimeout = 300;                       # сек (дефолт)
    deployUser = {
      authorizedKey = "ssh-ed25519 AAAA…";           # пара к deploy-ключу
      # name = "nixos-deploy";                       # дефолт
      # sshGate = "gate";                            # дефолт: restrict,command=<гейт>
    };
  };
}
```

Модуль провижинит: системного deploy-пользователя (невидим в SDDM),
root-юнит `nixtache-apply.service` (switch → probe `criticalUnits` → откат),
polkit-правило только на `start`, Tier-0 health-check, SSH-гейт.

### 1.3. Workflow-обёртка в consumer

`.forgejo/workflows/deploy.yml`:

```yaml
on: [ push, pull_request ]
jobs:
  deploy:
    uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main
```

Режим — по ветке: PR → `dry-activate`, `main` → `switch`. Хост недоступен →
skip с warning, CI не падает.

## 2. Переход с `system.autoUpgrade` на auto-update

```nix
# БЫЛО                          # СТАЛО
system.autoUpgrade = {           services.nixtache.auto-update = {
  enable = true;                   enable = true;
  flake = "git+ssh://…/nixos-configuration";
  dates = "daily";                 flake.url = "git+ssh://…/nixos-configuration";
};                                 dates = "daily";
                                   rebootPolicy = "if-needed";  # см. 09 §4
                                 };
```

Совместное включение с `system.autoUpgrade` — eval-ошибка (A1). flake-путь
строит toplevel и применяет через `nixtache-apply.service` (никакого
`nixos-rebuild`); для A/B-таргетов укажите `method = "ab-image"` (или
оставьте `auto`). Требует импорта `nixosModules.deploy-target` (A2).

## 3. BREAKING-изменения (чендж finalize-direct-deploy)

| Изменение | Миграция |
|---|---|
| Опция `deployUser.nixTrust` **удалена** | Убрать из конфига. Deploy-пользователь попадает в `nix.settings.trusted-users` **безусловно** — это протокольное требование `nix copy --to ssh://` (демон импортирует неподписанные локально собранные closure только для trusted users, nix.conf(5)). Нужен кастомный trust — задайте `nix.settings.trusted-users` сами |
| Deploy-пользователь теперь **системный** (`isSystemUser`, uid < 1000) | Ничего делать не надо: учётка исчезает из экранов входа (SDDM/Plasma). При странностях — удалите старего normal-пользователя (`sudo userdel nixos-deploy`) перед первым deploy |
| SSH-сессия ключа деплоя ограничена **гейтом** (`restrict,command=`) | Дефолт (`sshGate = "gate"`) пропускает только команды протокола деплоя. При дрейфе протокола (новый action ↔ старый модуль на целях) — временно `sshGate = "restrict"` и вернуть после синхронного обновления |
| `systemd-sysupdate-reboot.service` вместо plain | Удалённые A/B-таргеты перезагружаются после записи слота (активация!). Кому незапланированные ребуты не нужны — не триггерить вручную; auto-канал уважает `rebootPolicy` |
| `onSizeMismatch = "error"` маскирует sysupdate (runtime) | Ручное разрешение: поправить `slotSize` (или `wipe`), rebuild, `systemctl unmask --runtime systemd-sysupdate.service`, перезапустить provision-юнит |

## 4. Порядок обновления

1. Bump `inputs.nixtache` → `nix flake check` вашего флэйка: увидите eval-ошибки
   по BREAKING-пунктам выше (в первую очередь `nixTrust`).
2. Правки по таблице §3, деплой конфигурации раннер-хоста.
3. Один деплой на каждой цели (или `nixos-rebuild switch` локально) — модуль
   провижинит системного deploy-пользователя и гейт.
4. Smoke: PR → dry-activate → merge в main → switch; журнал цели
   `journalctl -u nixtache-apply.service`.

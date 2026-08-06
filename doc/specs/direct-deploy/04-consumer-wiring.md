# 04 — Consumer wiring

> Этап 4 из `0001` §11. Связывает `01` (карта) + `02` (action) + `06` (ab-image) в
> потребительскую инструкцию: что consumer пишет в `nixos-configuration`.
> **Статус:** 📝 черновик.

## Две стороны

| Сторона | Где в конфиге | Что |
|---|---|---|
| **A. Runner-host** (где крутится nixtache) | `server/services/deploy-*.nix` | sops deploy-ключи + наполнение карты `deploy.targets` + ab staging/nginx (06) |
| **B. Каждый таргет** (вкл. сам runner-host) | `common/` или `desktop|server/...` | импорт `nixtache.nixosModules.deploy-target` + `criticalUnits` + `deployUser` + (опц.) ab |

## A. Runner-host: ключи + карта

`server/services/deploy-keys.nix` — consumer владеет sops-секретами и кормит пути:
адреса хостов берёт из топологии amneziawg-меша (`common_secrets`), ключи — из sops.

```nix
{ config, common_secrets, ... }:
{
  sops.secrets.deploy-key-desktop = { sopsFile = ../../secrets/deploy-keys/desktop.ed25519; format = "binary"; };
  sops.secrets.deploy-key-laptop  = { sopsFile = ../../secrets/deploy-keys/laptop.ed25519;  format = "binary"; };

  services.nixtache.runner.deploy.targets = {
    desktop = {
      host          = common_secrets.network.amneziawg.nodes.desktop.ip;     # 10.13.37.3
      sshUser       = "nixos-deploy";
      sshPrivateKey = config.sops.secrets.deploy-key-desktop.path;
      method        = "live";              # default
      tags          = [ "lan" "vpn" ];
    };
    laptop = {
      host          = common_secrets.network.amneziawg.nodes.laptop.ip;
      sshUser       = "nixos-deploy";
      sshPrivateKey = config.sops.secrets.deploy-key-laptop.path;
    };
    server = {                            # self-update — ab-image (chicken-and-egg, §8)
      host          = common_secrets.network.server_ip;
      sshUser       = "nixos-deploy";
      sshPrivateKey = config.sops.secrets.deploy-key-server.path;
      method        = "ab-image";
    };
  };
}
```

## B. Таргет: приёмный модуль `deploy-target` (V2)

Импортируется в конфиг **каждой** машины (напр. общий `common/deploy-target.nix`):

```nix
{ inputs, ... }:
{
  imports = [ inputs.nixtache.nixosModules.deploy-target ];

  services.nixtache.deploy-target = {
    healthCheckTimeout = 300;                          # сек (Tier-0 + Tier-1 окно)
    criticalUnits      = [ "wireguard-awg0.service" ];  # пример universal — добавь что критично для твоих машин (nixtache-нейтрален, дефолт [])
    deployUser = {
      name          = "nixos-deploy";
      authorizedKey = "ssh-ed25519 AAAA…";             # соответствующий приватному из §A
      autoProvision = true;                            # модуль создаёт юзера + ключ + polkit
    };
  };
}
```

Per-target override (напр. `server/...` докидывает forgejo+контейнер в criticalUnits,
desktop — своё). AmneziaWG — в `common` для всех.

### `deployUser` — что провижинит модуль (`autoProvision = true`)

> **V2:** никакого sudo/doas/run0. Модуль ставит deploy-юзеру **только** SSH-доступ
> + членство в группе `nixtache-deploy` (write в pointer-dir) + polkit-правило.
> Всю root-работу делает root-юнит `nixtache-apply.service`.

- `users.users.${name}`: `isNormalUser` + `authorizedKeys.keys = [authorizedKey]`
  + `extraGroups = [ "nixtache-deploy" ]`.
- `users.groups.nixtache-deploy` (для ownership pointer-dir).
- **polkit-правило** `/etc/polkit-1/rules.d/49-nixtache-deploy.rules`: deploy-юзер
  может `start` ровно `nixtache-apply.service` (verb=start, только эту единицу).
- `security.polkit.enable = true` (force — транспорт без него не работает).
- При `autoProvision = false`: модуль **не** создаёт юзера/ключ (consumer сам), но
  **всё равно** добавляет юзера в группу + ставит polkit-правило + **assert'ит**
  `users.users.${name}`.

### deploy-юзер: ВСЯ его поверхность (least-privilege)

Деплоер, зайдя по SSH как этот юзер, может сделать ровно ТРИ вещи и ничего больше:

1. `nix copy --to ssh://<user>@<host> <closure>` — пишет closure в store цели
   (дефолт NixOS `nix.settings.allowed-users = ["*"]`); **не root**.
2. Write `/var/lib/nixtache/pending-system` (через группу `nixtache-deploy`) —
   pointer-файл с путём к closure; **не root**.
3. `systemctl start nixtache-apply.service` — root-юнит читает pointer, делает
   `nix-env --set` + `switch-to-configuration switch` + probe `criticalUnits` +
   rollback при fail; авторизовано polkit (только `start`, только этот юнит).

Никакого `sudo`/`doas`/`sudo-rs`/`run0` deploy-юзеру не нужно и не даётся. Это и
есть максимально root-less решение в рамках NixOS — escalation-тул нет вовсе,
systemd + polkit универсальны. (§9.2 `0001`, V2.)

### `nixtache-apply.service` (Tier-1 probe + rollback внутри)

Модуль генерирует root-юнит `nixtache-apply.service` (Type=oneshot):

1. читает `/var/lib/nixtache/pending-system` → closure path;
2. `nix-env -p /nix/var/nix/profiles/system --set <closure>`;
3. `<closure>/bin/switch-to-configuration switch`;
4. **Tier-1 probe**: в окне `healthCheckTimeout` локально опрашивает
   `systemctl is-active --wait <unit>` для каждого `criticalUnits`;
5. при fail → `nix-env --set <prev>` (захваченный до step 2) + повторный switch +
   `exit 1` (→ `systemctl start` вернёт ненулевой код по SSH → джоба краснеет);
6. при success → удаляет pointer.

Probe крутится на цели как root (dbus/systemctl) → работает даже если новый конфиг
сломал sshd (B1). Детали — `05-rollback.md`.

### Tier-0 oneshot (генерируется из `criticalUnits`)

Модуль создаёт `nixtache-health-check.service` (oneshot,
`Before=`+`RequiredBy=` `boot-complete.target`), который в окне
`healthCheckTimeout` ждёт `systemctl is-active --wait <unit>` для каждого
`criticalUnits`. Fail → `boot-complete.target` не достигнут → нет bless → (с
bootCounting, N1) откат generation на следующей загрузке. Детали — `05-rollback.md`.

## B'. ab-image таргет (опц., `method = "ab-image"`)

Поверх B, для ab-image-машин — `services.nixtache.deploy-target.ab.*`:

```nix
services.nixtache.deploy-target.ab = {
  enable = true;                       # + assert: systemd.sysupdate + bootCounting (prep в 06)
  gating = false;                      # true ТОЛЬКО на runner-host (server)
  # на runner-host:
  # gating              = true;
  # idleWaitTimeout      = 1800;
  # forceAfterTimeout    = false;
  # forgejoApiTokenFile  = config.sops.secrets.forgejo-actions-read.path;
};
```

Остальной prep (repart-слоты / UKI / `systemd.sysupdate` transfers / `system.image.{id,version}`
/ подпись) — `06-ab-image.md` §1–7. staging/nginx/gating-unit предоставляет nixtache (06).
Триггеры ab-image (`touch ab-pending`, `systemctl start systemd-sysupdate`/`nixtache-ab-apply`)
deploy-юзер делает через **polkit** (как и `start nixtache-apply.service` для live) —
отдельные polkit-правила, без sudo.

## Asserts (eval-fail с понятным сообщением)

- `method = "ab-image"` в карте раннера ⟺ `ab.enable = true` на таргете ⟺
  `systemd.sysupdate.enable` + `boot.loader.systemd-boot.bootCounting.enable`.
- `deployUser.autoProvision = false` → `users.users.${name}` существует.
- `ab.gating = true` → `forgejoApiTokenFile` задан.
- (V2) `transport` поля нет — модуль всегда провижинит `nixtache-apply.service`
  + polkit (без sudo-rule); выбора escalation-тула не требуется.

## Артефакты consumer'а

- `server/services/deploy-keys.nix` — sops deploy-ключи + карта `deploy.targets` (§A).
- `common/deploy-target.nix` — импорт приёмного модуля + universal `criticalUnits`
  (AmneziaWG) + `deployUser` (§B).
- `desktop|server/...` — per-target overrides (`criticalUnits`, `ab.*`).
- `secrets/deploy-keys/*.ed25519` (age) + `secrets/forgejo-actions-read` (для gating).
- Для ab-image: repart/UKI/sysupdate config per-target (06 §1–6).

## Зависимости / следующие этапы

- ← `01` (карта), `02` (action), `06` (ab-image prep).
- → `05-rollback.md` (Tier-0/1 детально; Tier-1 probe+rollback внутри
  `nixtache-apply.service`, V2).

# 06 — A/B image-update (systemd-sysupdate)

> Per-target метод `targets.<name>.method = "ab-image"` (default `"live"`).
> Атомарное A/B-обновление образов для **нескольких** таргетов — локальных
> (runner-host self-update) и удалённых. Решает chicken-and-egg сервера + не рвёт
> бегущие джобы (local-self: idle-gated reboot).
> База: nixcademy «Immutable A/B system partitions with NixOS for OTA updates» +
> `applicative-systems/nixos-appliance-ota-update`.
>
> **Статус:** nixtache-сторона ✅ реализована (Batch E: `modules/runner/ab.nix` +
> `modules/deploy-target/ab.nix` + action `_abImage` + тесты); consumer-сторона 📝
> (gated, требует bump nixtache + reinstall server). См. `IMPLEMENTATION-PLAN.md`.

> ### Сверено с `sysupdate.d(5)` (применено в реализации)
> - **Верификация — только GPG/OpenPGP** (захардкожено в апстриме systemd через
>   gpgme). age/sops/minisign/cosign как подпись **невозможны** — `Verify` ждёт
>   detached-сигнатуру `SHA256SUMS.gpg`. age допустим только для ХРАНЕНИЯ
>   приватного GPG-ключа (sops-encrypted секрет → импорт временным GNUPGHOME в CI).
> - **`[Source] Path` СТАТИЧЕН** — `@v` живёт **только** в `MatchPattern=`. sysupdate
>   тянет `<Path>/SHA256SUMS` (+ `.gpg`), парсит версии из имён по `MatchPattern`.
> - **`[Transfer] Verify` по умолчанию `yes`**. Публичный keyring —
>   `/usr/lib/systemd/import-pubring.pgp` или `/etc/systemd/import-pubring.pgp`.
> - **Один `SHA256SUMS` на `<Path>`** (per-cfg dir в central staging).

## Почему не `method = "live"` (root-юнит)

`method = "live"` (`nixtache-apply.service`) активирует **profile** in-place —
не умеет писать A/B-слоты и не переживает рестарт контейнера, в котором бежит
деплоер (chicken-and-egg сервера). Поэтому `ab-image` — отдельная ветка action'а:
CI готовит образ → host-овый `systemd-sysupdate` цели пишет неактивный слот.
**Контейнер (CI) не пишет слот
сам** (нет доступа к block device) — CI только **stage'ит образ в central store**.

## Топология: central staging + два класса таргетов

Один **central staging-dir на runner-host** (`/var/lib/nixtache/ab-stage/`,
per-cfg dir с versioned-файлами `<cfg>/<id>_<version>.{raw,efi}`) держит образы
**всех** ab-image-таргетов. nginx
(nixtache) раздаёт его по HTTPS. Таргеты читают откуда могут:

| Таргет | source sysupdate | apply | idle-gate? |
|---|---|---|---|
| **local-self** (runner-host = цель, напр. server) | `/var/lib/nixtache/ab-stage/` (тот же dir, plain path — sysupdate отвергает `file://` URI для regular-file source) | CI сигналит `nixtache-ab-apply` → idle-wait → `systemd-sysupdate-reboot.service` | **да** (не рвать джобы) |
| **remote** (цель ≠ runner-host) | `https://<runner-host>/ab-stage/…` (nginx) | sysupdate-таймер цели тянет по HTTPS (pull, асинхронно); CI опц. SSH-триггерит `systemd-sysupdate-reboot.service` | нет (раннеров на цели нет) |

sysupdate на каждом таргете **сам** выбирает старшую версию по `MatchPattern`
(central store — источник правды по версиям).

## Механика

```
1. Build:  CI собирает system-image для cfg (UKI + <id>_<v>.nix-store.raw + SHA256SUMS)
2. Stage:  CI пишет в CENTRAL staging на runner-host (per-cfg dir, versioned files):
           /var/lib/nixtache/ab-stage/<cfg>/<id>_<version>.{nix-store.raw,efi} + SHA256SUMS.
           Хост-dir bind-mount'нут в контейнер (CI пишет); nginx раздаёт по HTTPS.
3. Apply:
   - local-self: CI сигналит host-овый nixtache-ab-apply (pending) →
       idle-wait раннеров (Forgejo API) → systemctl start systemd-sysupdate →
       sysupdate читает file:// → пишет слот B → reboot → снять pending
   - remote: sysupdate цели по своему таймеру тянет HTTPS → пишет слот → reboot
       (CI опц. SSH-триггерит systemctl start systemd-sysupdate для немедленного)
4. Rollback: boot-counting (N1) — слот B не дошёл до boot-complete.target → откат к A
```

Деплоер (контейнер на runner-host, слот A) переживает 1–2 + (local-self) сигнал 3
— слот A не тронут. Дизруптивен только reboot, и для local-self он **ждёт idle**.

### Условие switch = runner-idle (только local-self)

Для **local-self** (runner-host) reboot в B — только когда все nixtache-раннеры на
этой машине `busy=false` (Forgejo API). Занято → gating ждёт в пределах
`idleWaitTimeout`; дальше — `forceAfterTimeout` (опц.) или ждёт дальше. Для
**remote** idle-gate не нужен (раннеров на цели нет) — sysupdate применяется по
таймеру/триггеру без ожидания.

## Создание staging-dir + конкурентность

**Кто создаёт `/var/lib/nixtache/ab-stage/`:** nixtache runner-модуль, декларативно
(`StateDirectory` на runner-host) при `ab.enable = true`, + bind-mount в контейнер
+ nginx-vhost раздаёт по HTTPS. CI в рантайме диру **не создаёт** — пишет в готовую.

**Почему central хост-dir, а не per-container / per-target локальные:**
- sysupdate local-self крутится на runner-host и читает `file://` — должен видеть
  то, что CI (контейнер) записал. Per-container диры хост-овый sysupdate не видит.
- Для remote — тот же central-dir раздаётся по HTTPS; дублировать staging на каждой
  remote-цели не нужно (тянут из центра).

**Конкурентность (несколько таргетов / одновременные джобы):**
- **Per-cfg dir + versioned-файлы** `<cfg>/<id>_<version>.{raw,efi}` — иммутабельны;
  конкурентные сборки разных cfg/версий не перезаписывают друг друга.
- **sysupdate выбирает старшую версию** по `MatchPattern` — две конкурентные сборки
  одной cfg не теряются; применяется свежая.
- **`concurrency.group: deploy-${ref}`** в workflow сериализует deploys одного ref.
- **GC старых version-файлов** (retain N на cfg) — рост central-store ограничен.
- pending-сигнал (local-self) — level-triggered («есть неприменённое»); гонки нет,
  источник правды по версии — central-store, а не флаг.

## Consumer-side: что приготовить (per-target, для `ab-image`)

> Без этого assert приёмного модуля зафейлится («нет sysupdate/слотов — см. 06»).
>
> **M2:** `image.repart.*` — real NixOS-опция (модуль `nixos/modules/image/repart.nix`
> в nixpkgs, verified), но **не входит в дефолтный import-list**. Consumer обязан
> добавить её явно в `imports` таргета, иначе `option image.repart not found`:
> ```nix
> imports = [ "${nixpkgs}/nixos/modules/image/repart.nix" ];
> ```

0. **`imports`** — добавить `${nixpkgs}/nixos/modules/image/repart.nix` (даёт
   опцию `image.repart.*`, см. M2 выше). Без него шаг 1 не провалится — зафейлится
   сам eval.
1. **Partition layout: 2 nix-store слота** (`image.repart`): squashFS slot A + пустой
   slot B **равного размера** + ESP + root.
2. **UKI + systemd-boot** (загрузчик обязателен — boot-counting): UKI в ESP.
3. **`systemd.sysupdate` transfers** — source по топологии таргета (per-cfg subdir);
   per-transfer reboot-флага у sysupdate НЕТ — ребут даёт выбор ЮНИТА:
   `systemd-sysupdate.service` (только запись слота) vs
   `systemd-sysupdate-reboot.service` (запись + ребут):
   - **local-self**: `Source = /var/lib/nixtache/ab-stage/<cfg>/` (plain absolute
     path), `Type = "regular-file"`; ребут триггерит gating-юнит
     (`nixtache-ab-apply` → `systemd-sysupdate-reboot.service` после idle-wait);
   - **remote**: `Source = https://<runner-host>/ab-stage/<cfg>/`, `Type = "url-file"`
     (sysupdate сканит HTTPS autoindex'ом — нужен `autoindex on`, см. nixtache-side);
     CI-триггер и авто-канал используют `systemd-sysupdate-reboot.service`,
     чтобы новый слот активировался ребутом;
   - общий: `MatchPattern` `<id>_@v.nix-store.raw` / `<id>_@v.efi`, `InstancesMax = 2`.
4. **`system.image.id`** (фикс.) + **`system.image.version`** (per build).
   **Версия назначается в РАНТАЙМЕ, не декларативно:** consumer коммитит файл
   `image-version` (содержимое `0`) и ставит
   `services.nixtache.ab-image.imageVersionFile = ./image-version;` — deploy
   action перезаписывает файл вычисленной версией (UTC calver
   `YYYYMMDDHHMMSS`, монотонен под strverscmp; override —
   `NIXTACHE_AB_VERSION`) прямо перед `nix build` (+ `git add -f`: flake
   читает git index). Тогда os-release = UKI = staged-имена = GPT label —
   все несут одну runtime-версию, а flake остаётся pure. Явный
   `imageVersion = "…"` в конфиге — для тестов/разового bootstrap.
5. **Boot counting** (N1): `systemd-boot.bootCounting.enable = true`, `boot.uki.tries = 3`
   + Tier-0 `criticalUnits`.
6. **Подпись образа** (рекомендуется) + `Transfer.Verify`.
7. **(local-self only) Forgejo API token** в sops → gating idle-check `/actions/runners`.
8. **`services.nixtache.deploy-target.ab.enable = true`** (+ для runner-host
   `ab.gating = true`) — провижинит чтение staging + (gating-unit) на этой машине.
9. **Регистрация в карте**: `targets.<target>.method = "ab-image"` + host/sshUser/key.

## nixtache-side: детально (options + nginx + gating-unit)

### Runner-модуль: `services.nixtache.runner.deploy.ab.*`

```nix
services.nixtache.runner.deploy.ab = {
  enable         = true;                            # central staging + nginx location + env
  stagingPath    = "/var/lib/nixtache/ab-stage";    # StateDirectory на runner-host
  runnerHost     = "bincache.zinzaguras.ru";        # → $NIXTACHE_RUNNER_HOST (self/remote check)
  nginx.location = "/ab-stage/";                    # path на cache-vhost'е (reuse domain+TLS)
  retain         = 5;                               # GC: хранить N последних версий на cfg
};
```

**Поведение при `enable = true`:**
- `systemd.tmpfiles.rules` (или `StateDirectory`) создаёт `stagingPath` на runner-host.
- `containers.${containerName}.bindMounts."ab-stage"`: `hostPath = stagingPath`,
  `mountPoint = stagingPath`, `isReadOnly = false` (CI пишет образы).
- env `NIXTACHE_RUNNER_HOST = runnerHost` → в `runner.envs` (как `NIXTACHE_*_GIT_USER`).
- systemd timer `nixtache-ab-gc.{timer,service}`: чистит versioned-файлы старше N-й
  версии в каждом `<cfg>/` (retain) — рост central-store ограничен.
- **assert**: `ab.enable = true` требует `cache.enable = true` (nginx vhost reuse)
  и что basename `stagingPath` совпадает с basename `nginx.location`.

### nginx vhost (host-side, reuse cache vhost)

Добавляется `location` в существующий cache-vhost (`cache.nix`:
`services.nginx.virtualHosts.${cache.domain}` с `enableACME`/`forceSSL`):

```nix
services.nginx.virtualHosts.${cfg.cache.domain}.locations.${cfg.deploy.ab.nginx.location} = {
  # root = родитель stagingPath → URI /ab-stage/<cfg>/<id>_<v>.raw
  #        маппится на <stagingPath>/<cfg>/<id>_<v>.raw
  root = builtins.dirOf cfg.deploy.ab.stagingPath;   # "/var/lib/nixtache" при дефолте
  extraConfig = ''
    autoindex on;                          # sysupdate сканит версии по HTTPS dir-listing'у
    default_type application/octet-stream; # .raw / .efi
    location ~ /SHA256SUMS$ { default_type text/plain; }
    location ~ \.sig$       { default_type application/pgp-signature; }
  '';
};
```

Remote-таргет тянет `https://<cache.domain>/ab-stage/<cfg>/<id>_<v>.nix-store.raw`
(sysupdate `Type = url-file`, `MatchPattern`, сверяет SHA256SUMS). TLS/domain — от
cache-vhost, отдельный HTTPS-сервер consumer не поднимает.

### Приёмный модуль (на каждом ab-image-таргете): `services.nixtache.deploy-target.ab.*`

```nix
services.nixtache.deploy-target.ab = {
  enable              = true;          # ожидает systemd.sysupdate + bootCounting (assert)
  gating              = false;         # true ТОЛЬКО на runner-host (idle-wait gating-unit)
  idleWaitTimeout     = 1800;          # сек ожидания idle раннеров
  forceAfterTimeout   = false;         # true → после таймаута применить даже если занято
  forgejoApiTokenFile = config.sops.secrets.forgejo-actions-read.path; # read:actions (gating only)
};
```

**gating-unit (провижинится при `ab.gating = true`, только runner-host):**

> **S2/S3 (решено):** `forgejoPort` — новая опция на runner-модуле (`services.nixtache.runner.forgejoPort`,
> numeric; дефолт парсится из `forgejoUrl`). `systemd.paths.<name>.pathExists`
> неверная API — правильно `pathConfig.PathExists`.

```nix
systemd.paths.nixtache-ab-apply = {
  description = "Trigger A/B apply when a new image is staged";
  wantedBy    = [ "multi-user.target" ];
  pathConfig.PathExists = "/var/lib/nixtache/ab-pending";   # level-triggered (CI touch'ит)
};
systemd.services.nixtache-ab-apply = {
  path = [ pkgs.systemd pkgs.curl pkgs.jq ];
  serviceConfig = {
    Type = "oneshot";
    LoadCredential = [ "forgejo-api:${cfg.ab.forgejoApiTokenFile}" ];
  };
  script = ''
    deadline=$(( $(date +%s) + ${toString cfg.ab.idleWaitTimeout} ))
    busy=1
    while [ "$(date +%s)" -lt "$deadline" ]; do
      busy=$(curl -sf -H "Authorization: token $(cat ''${CREDENTIALS_DIRECTORY}/forgejo-api)" \
             http://localhost:${toString config.services.nixtache.runner.forgejoPort}/api/v1/actions/runners \
             | jq '[.[] | select(.busy==true)] | length')
      [ "$busy" = "0" ] && break
      sleep 10
    done
    if [ "$busy" != "0" ] && [ "${toString cfg.ab.forceAfterTimeout}" != "1" ]; then
       echo "runners busy, forceAfterTimeout=false — оставляю pending"; exit 0
    fi
    systemctl start systemd-sysupdate.service   # file:// latest → слот B → reboot
    rm -f /var/lib/nixtache/ab-pending
  '';
};
```

**Поведение:** `nixtache-ab-apply.path` срабатывает по появлению `ab-pending` →
service крутит idle-poll (Forgejo API `/actions/runners`, `busy==false` всех
nixtache-раннеров) в пределах `idleWaitTimeout` → запускает `systemd-sysupdate`
(читает `file://` из staging, берёт старшую версию, пишет слот B, ребутает; отказ
— `boot.uki.tries`/boot-counting) → снимает pending. `forceAfterTimeout` —
применить принудительно по истечении.

**assert приёмного модуля:** `ab.enable = true` ⟺ в карте раннера `method = "ab-image"`
для этого cfg ⟺ `systemd.sysupdate.enable = true` +
`boot.loader.systemd-boot.bootCounting.enable = true` на таргете. Иначе eval-fail с
понятным сообщением. `ab.gating = true` дополнительно требует `forgejoApiTokenFile`.

### action-ветка `method = "ab-image"` (см. `02-action.md`)

build `sysupdate-package` → `cp` в `stagingPath/<cfg>/` → (local-self:
`touch ab-pending`) / (remote: SSH `systemctl start systemd-sysupdate`).

## Разделение по классам машин

| Класс | `method` | notes |
|---|---|---|
| desktop/laptop (default) | `live` | nix copy + root-юнит `nixtache-apply.service`, zero prep |
| **server (runner-host, self)** | `ab-image` (local-self) | chicken-and-egg + idle-gated reboot |
| **remote ab-image-таргет** | `ab-image` (remote) | atomic image-rollback, pull by HTTPS |

Любую машину можно перевести на `ab-image`; default `live` — без prep.

## Трейдоффы

- **Ребут** на каждый апдейт ab-image-машины (local-self — по idle, без обрыва джоб).
- **Сборка disk-image** в CI (дольше/больше места, чем toplevel); central-store растёт
  (GC version-дир).
- **Зрелость**: sysupdate на полном NixOS (не appliance) — свежее (2025).
- **Idle-wait latency** (local-self): применяется не мгновенно, а когда runners freed
  (`idleWaitTimeout`). Фича (не рвёт джобы), не баг.
- **network dependency** (remote): нужен HTTPS до runner-host (VPN/LAN).

## Артефакты

- **nixtache**: action `deploy-target` — ветка `method = "ab-image"` (build +
  central-stage + apply per топологии); runner-модуль — central staging-dir +
  nginx-vhost; приёмный модуль — `ab.{enable,gating,idleWaitTimeout,
  forgejoApiTokenFile,forceAfterTimeout}` + `nixtache-ab-apply.{path,service}`
  (gating только на runner-host); assert `ab.enable` ⟺ `method=ab-image` ⟺
  `systemd.sysupdate.enable` + `bootCounting` на таргете.
- **consumer**: repart-слоты + UKI + `systemd.sysupdate` (file:// self / https remote)
  + boot-counting + `system.image.{id,version}` + подпись + (self) Forgejo API token.
- **тесты** (`tests/deploy-target.nix`): `ab.enable` → staging/nginx wired; `ab.gating`
  → gating-unit wired (runner-host only); assert требует sysupdate + bootCounting;
  versioned-stage — две версии одной cfg не конфликтуют.

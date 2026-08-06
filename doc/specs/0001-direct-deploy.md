# Спека 0001 — Прямой деплой NixOS-машин из consumer CI


> **Статус:** финал (все вопросы Q1–Q9, N1–N6 закрыты; готова к имплементации, поэтапная детализация в `doc/specs/direct-deploy/`)
> **Дата:** 2026-08-05 (итерации 2026-08-06: Forgejo `environment`, A/B image (sysupdate), cross-arch, root-less, multi-tier rollback)
> **Зона:** `nixtache` (reusable `deploy.yml` + action `deploy-target` + опции runner-модуля)
> + `nixos-configuration` (consumer-side карта целей + deploy-ключи)
> **Ссылки:** `doc/migration-plan.md` §6 «Контракт деплоя» (стабы);
> `AGENTS.md` «Bootstrap & deploy: the chicken-and-egg».

---

## 1. Цель

**Назначение фичи — сократить задержку доставки новых дериваций на машины.**
По умолчанию машины обновляются сами через `system.autoUpgrade` по расписанию
(см. «Модель доставки» ниже) — автономно, но медленно (таймер). Эта фича
доставляет свежесобранные конфиги на машины **сразу после успешной сборки**
(зелёный `nix-check`), не дожидаясь таймера. Поэтому основной путь
**автофайрится** (по триггеру `workflow_run` на успех `nix-check`), а не ждёт
ручного запуска.

При запуске consumer CI (`push`/`workflow_run` на успех сборки / `workflow_dispatch`) деплоер должен:

1. перечислить все `nixosConfigurations` потребителя;
2. для каждой найти запись в **карте целей** `config → host → creds`;
3. для машин, до которых есть доступ (креды заданы **и** хост отвечает по SSH),
   собрать конфигурацию и **активировать её прямо на машине**;
4. машины без записи в карте или без кредов — **молча пропустить**
   (опциональность по построению);
5. машины, есть креды, но хост недоступен (выключен / VPN вниз) — пропустить
   с предупреждением, но не валить весь пайплайн.

Ключевая модель данных — **карта**:

```
config → host → creds
```

- `config` — имя атрибута `nixosConfigurations.<name>` (например `desktop`);
- `host`  — как до машины дотянуться (адрес, SSH-пользователь, порт);
- `creds` — SSH-ключ (путь), которым раннер аутентифицируется на машине.

### Модель доставки (два пути)

Изменения попадают на машины **двумя** путями — их надо различать:

1. **Pull-based auto-update — ДЕФОЛТ, автономный.** Каждая машина (включая хост
   nixtache) крутит `system.autoUpgrade` (`flake = git+ssh://…/nixos-configuration`,
   `operation = "switch"`, по таймеру `dates`). По расписанию машина **сама**
   тянет свежий flake и свитчится — **без участия человека**. Для рутинных
   изменений этого достаточно, CI вообще не нужен. На хосте nixtache `autoUpgrade`
   бежит host-level таймером (не в контейнере) → routine-обновления сервера **не**
   имеют chicken-and-egg (§8).

2. **CI `deploy` workflow — ускоритель доставки (в этом и смысл фичи).**
   Автофайрится на успех `nix-check` и применяет конфиг **сразу**, не дожидаясь
   таймера `autoUpgrade`. Дополнительно: cross-machine деплой с серверного CI
   по SSH (карта §5); видимость/артефакты в CI; recovery — когда `autoUpgrade`
   сломал машину, CI передеплоит/катит назад (method = "live" — root-юнит для
   desktop/laptop, ab-image для server, §8). Ручной
   `workflow_dispatch` — для форсирования вне триггера / выбора конкретного
   таргета.

Оба пути заканчиваются `switch` и покрыты auto-rollback (§8.5). `mode:
dry-activate` в CI-воркфлоу — безопасный предпросмотр (сборка + дифф без
активации); реальное применение по умолчанию идёт через `autoUpgrade`, а из CI
на `main` — `switch` (после merge, по §7.1).

### Не-цели (out of scope)

- Первичная установка машин с нуля (`nixos-anywhere`) — отдельно.
- Деплой не-NixOS артефактов (контейнеры, статика).

> **Авто-rollback переведён в скоуп** (раньше был не-целью): многоуровневый
> health-check + auto-rollback для **всех** таргетов — см. §8.5. Ручной
> `nixos-rebuild --rollback` остаётся последним fallback'ом.

---

## 2. Требования и ограничения

| # | Требование | Как обеспечено |
|---|---|---|
| R1 | **Опциональность** — нет записи в карте / нет кредов → данная `nixosConfiguration` не деплоится | Карта — единственный источник правды; шаг discovery фильтрует по ней |
| R2 | **Vendor-agnostic** — `nixtache` не хардкодит хосты/домены/ключи | Карта и ключи задаются потребителем через опции модуля (параметризация) |
| R3 | `nixtache` **не хранит секреты** | deploy-ключи — `types.path`, поставляются потребителем (sops/agenix/vault/systemd) |
| R4 | Совместимость с существующим path-based контрактом | Те же паттерны, что `flakeSshCreds`/`instances.<name>.tokenFile` |
| R5 | Недоступный хост не роняет CI | Шаг probe с коротким `ConnectTimeout`; fallback = skip+warn |
| R6 | `mode: switch` защищён от случайного запуска | Mode по ветке: `switch` только на `main` после merge (PR review = гейт); на PR — `dry-activate`. У Forgejo нет `environment:`-rules (см. §7.1, §9.1) |
| R7 | Сервер не может live-деплоить сам себя из своего же контейнера | Chicken-and-egg решается A/B image-update (`method = "ab-image"`, systemd-sysupdate) — см. §8 |

---

## 3. Контекст (что уже есть)

- `nixos-configuration/flake.nix` объявляет `nixosConfigurations.{desktop,laptop,server}`.
- `nixos-private/common.nix` → `common_secrets.network`:
  - `server_ip = "192.168.100.2"` (LAN);
  - `amneziawg.nodes.{server,laptop,desktop}` — full-mesh VPN с IP/публичными
    ключами (`10.13.37.{1,2,3}`), `server` — хаб с публичным `endpoint`. Это
    готовая топология сети, откуда потребитель берёт адреса хостов.
- CI-раннер живёт на `server` в NixOS-контейнере (`services.nixtache.runner`,
  wired в `nixos-configuration/server/services/forgejo-runner.nix`).
- `nixtache/.forgejo/workflows/nix-check.yml` + action `rebuild-configurations`
  **уже** перечисляют `nixosConfigurations` через `nix flake show --json` и
  собирают `.config.system.build.toplevel` — то есть **сборка уже работает**,
  не хватает только шага активации.
- `doc/migration-plan.md` §6 зарезервировал стабы `deploy.yml` + action
  `deploy-target`; `AGENTS.md` «Bootstrap & deploy» описал chicken-and-egg и
  дизайн bootstrap-раннера. Эта спека — реализация того контракта.

---

## 4. Где живёт карта (решение)

**Решение: карта целей — NixOS-опция на runner-модуле**, настраивается на
хосте, где стоит CI-раннер (т.е. на `server`), и описывает **весь флот** машин,
до которых этот раннер может деплоить:

```nix
services.nixtache.runner.deploy.targets.<name> = {
  enable     = true;
  host       = "10.13.37.3";      # config → host (адрес)
  sshUser    = "nixos-deploy";    # config → host (пользователь)
  sshPort    = 22;
  sshPrivateKey = config.sops.secrets.deploy-key-desktop.path;  # → creds
  # необязательные поля (см. §5)
};
```

Имя атрибута `<name>` **совпадает** с именем `nixosConfigurations.<name>` —
по нему discovery-шаг сопоставляет конфиг и цель.

### Почему опция модуля, а не отдельный fleet-файл / Forgejo-секреты

Рассмотрены 3 варианта:

| Вариант | Плюсы | Минусы → отказ |
|---|---|---|
| **A. Опция runner-модуля (выбрано)** | Единая точка wired'а; секреты как `types.path` (sops/vault/systemd — любой бэкенд); ключи монтируются через `LoadCredential` ровно как `flake_ssh_*`/`update_ssh_*`; consumer-side карта читается из своего secrets-флэйка (`common_secrets.network.amneziawg.nodes.*`) | — |
| B. Fleet-манифест отдельным flake-output (`deploy.targets`) | Декларативно, видно в `nix flake show` | Манифест не имеет доступа к `config.sops.secrets.*` вне `nixosSystem`-евала → пришлось бы хардкодить пути-строки; двойной источник правды (манифест + где-то ещё лежат ключи) |
| C. Forgejo CI-секреты (`${{ secrets.DEPLOY_KEY_* }}`) | Ноль Nix-кода | Ключи утекают в workflow-env (видны в логах/step-окружении); не работает с sops/vault-на-хосте; адреса хостов пришлось бы тоже тащить через переменные; ломает path-based контракт |

Вариант A максимально переиспользует существующие паттерны nixtache
(`flakeSshCreds`/`updateSshCreds`/`instances.<name>.tokenFile` — везде секреты
это `types.path`, везде `LoadCredential`) и оставляет `nixtache` vendor-agnostic:
модуль лишь объявляет **форму** карты, потребитель наполняет её значениями
(в т.ч. беря адреса из своего приватного secrets-флэйка).

---

## 5. Контракт данных: `deploy.targets.<name>`

Подмодуль-тип (`modules/runner/types.nix` → `deployTargetType`):

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `enable` | `bool` | `true` | `false` = цель объявлена, но деплой выключен (быстрый toggle без удаления записи) |
| `host` | `str` | **обязательный** | Адрес машины: LAN-IP / VPN-IP / публичный IP / DNS. Это **config → host** |
| `sshUser` | `str` | `"nixos-deploy"` | Пользователь для SSH-транспорта (должен совпадать с `deployUser.name` приёмного модуля §9.2). `sshPrivateKey` от этого юзера идёт на `nix copy` + pointer-write + `systemctl start` (см. §7.2) |
| `sshPort` | `int` | `22` | Нестандартный SSH-порт |
| `method` | `enum` | `"live"` | Как обновлять цель: `"live"` (default — `nix copy` + root-юнит `nixtache-apply.service` по polkit) или `"ab-image"` (A/B-слот через `systemd-sysupdate` — chicken-and-egg хоста nixtache; см. §8, `direct-deploy/06-ab-image.md`). `ab-image` требует consumer-prep |
| `sshPrivateKey` | `nullOr path` | `null` | Приватный ключ деплоя (**host → creds**). Обязателен для обоих `method`: live (SSH-триггер apply-юнита + `nix copy`) и ab-image (SSH-триггер sysupdate) |
| `sshPublicKey` | `nullOr path` | `null` | Соответствующий публичный ключ (опц., для known_hosts / проверки) |
| `system` | `nullOr str` | `null` | Архитектура цели (`x86_64-linux`). `null` = взять из `nixosConfigurations.<name>.config.nixpkgs.hostPlatform` |
| `extraOptions` | `listOf str` | `[]` | Доп. флаги (напр. `["--no-substitute-on-target"]` для `nix copy`) |
| `tags` | `listOf str` | `[]` | Группировка целей (метки для документации/фильтрации) |
| `timeout` | `int` (мин) | `240` | Per-target таймаут сборка+активация |

> **Убранные поля (V2):**
> - `mode` — режим определяется веткой (§7.1: `main` → `switch`, PR → `dry-activate`), не per-target.
> - `transport` — активация всегда через root-юнит `nixtache-apply.service` + polkit (без sudo/doas/run0); выбор escalation-тула исчез вместе с полем.
> - `buildHost` — cross-arch через `boot.binfmt.emulatedSystems` на раннере (`direct-deploy/07-cross-arch.md`), без отдельного поля.

> **`enable = false` vs. отсутствие записи:** отсутствие записи в карте =
> машина не предназначена для автодеплоя (никогда не пытаются). `enable = false`
> = временно выключена (пропускается с warning'ом, удобно для отладки).

> **Cross-arch (Q6):** поле `system = null` (дефолт) → derive из
> `nixosConfigurations.<name>.config.nixpkgs.hostPlatform`. Архитектура
> объявляется **в конфиге хоста** (`nixpkgs.hostPlatform`), а не флагом в
> rebuild. Cross-arch теперь first-class requirement, а не «все три x86_64» —
> см. подзадачу §11.9 и вопросы §12.D.

### Как карта попадает в CI-джобу

Runner-модуль (новый `modules/runner/deploy.nix`,.merge в тот же контейнер):

 1. **Export env** `NIXTACHE_DEPLOY_TARGETS` = JSON-сериализация карты **без**
    секретных путей (только `{name, host, sshUser, sshPort, method, system, tags,
    timeout, hasKey}`) — добавляется в `runner.envs` через агрегатор
    `_extraRunnerEnvs` (см. `instances.nix`, S1). `hasKey: bool` = задан ли
    `sshPrivateKey` (драйвит «креды не заданы → skip»).
2. **LoadCredential** одного приватного ключа на цель:
   `deploy_ssh_<name>:/var/secrets/runner/deploy/<name>/id_ed25519`
   (bind-mount hostPath → `sshPrivateKey`, `isReadOnly = true`). Аналогично
   `deploy_ssh_<name>.pub` если задан `sshPublicKey`. Шаг `deploy-target`
   читает ключи из `$CREDENTIALS_DIRECTORY`.

Так в джобу приходит и карта (env, чистые данные), и ключи (LoadCredential,
пути) — ровно та же связка, что уже работает для flake/update-кред.

---

## 6. Поставка секретов (deploy-ключи)

Path-based контракт, идентичный `flakeSshCreds`. **Consumer** (в
`nixos-configuration`) владеет объявлениями sops и кормит пути:

```nix
# nixos-configuration/server/services/deploy-keys.nix (НОВОЕ у потребителя)
{ config, common_secrets, ... }:
{
  sops.secrets.deploy-key-desktop = {
    sopsFile = ../../secrets/deploy-keys/desktop.ed25519;
    format   = "binary";
  };
  sops.secrets.deploy-key-laptop = {
    sopsFile = ../../secrets/deploy-keys/laptop.ed25519;
    format   = "binary";
  };
  # server не получает ключ из контейнера (chicken-and-egg, см. §8)

  services.nixtache.runner.deploy.targets = {
    desktop = {
      # адрес берётся из топологии amneziawg-меша (единый источник правды)
      host         = common_secrets.network.amneziawg.nodes.desktop.ip; # 10.13.37.3
      sshUser      = "nixos-deploy";
      sshPrivateKey = config.sops.secrets.deploy-key-desktop.path;
      tags         = [ "lan" "vpn" ];
    };
    laptop = {
      host          = common_secrets.network.amneziawg.nodes.laptop.ip;  # 10.13.37.2
      sshUser       = "nixos-deploy";
      sshPrivateKey = config.sops.secrets.deploy-key-laptop.path;
      tags          = [ "vpn" ];
    };
    # server — в карте с `method = "ab-image"` (chicken-and-egg: live-switch
    # рестартит контейнер и убьёт джобу). ab-image пишет неактивный слот через
    # systemd-sysupdate — деплоер (контейнер) живёт. См. §8, direct-deploy/06-ab-image.md.
  };
}
```

**На целевой машине** публичный ключ деплоя прописывается в
`users.users.nixos-deploy.openssh.authorizedKeys`; привилегии (polkit на
`systemctl start nixtache-apply.service` + группа `nixtache-deploy` для pointer-
dir) провижинит приёмный модуль — см. §9.2 (поверх §6 — consumer даёт ключ,
модуль даёт разрешения; **без sudo/doas/run0** — V2).

> Любой другой бэкенд (agenix, vault-agent, systemd LoadCredential) работает
> тем же контрактом — достаточно подсунуть `sshPrivateKey = <путь>` из него.

---

## 7. Workflow: discovery → probe → deploy

Reusable workflow `nixtache/.forgejo/workflows/deploy.yml` (`on: workflow_call`
+ `workflow_run` на успех сборочного stage'а; опц. `workflow_dispatch` **без
inputs**), тонкая обёртка в consumer по аналогии с `nix-check.yml`. **Inputs
убраны** — режим определяется веткой.

### 7.1. Режим активации — по ветке (без inputs)

| Событие | Ветка | `mode` | Смысл |
|---|---|---|---|
| `pull_request` (открыт/обновлён) | любая, ≠ `main` | `dry-activate` | предпросмотр диффа в PR; **PR review = гейт** |
| `push` / merge | `main` (default branch) | `switch` | применить сразу — **быстрая доставка** |

Триггер — `on.workflow_run` на успех `nix-check.yml` (он строит все
`nixosConfigurations` + `devShells`): деплой стартует **когда всё собралось**.
`mode` выводится из ветки и передаётся в action (§7.2).

> **Сходимость с `autoUpgrade`:** `system.autoUpgrade` тянет flake по дефолтному
> ref'у (`main`). PR-ветку он не подхватит → на PR нигде ничего не мутирует (CI
> даёт только `dry-activate`, `autoUpgrade` игнорит не-`main`). На `main` CI
> применяет `switch` сразу, а `autoUpgrade` перестраховочно применит ещё раз по
> таймеру. Модели согласованы.

### 7.2. Алгоритм (action `deploy-target`, V2 — systemd-unit активация)

> Активация **без deploy-rs и без sudo/doas/run0**: копирование closure через
> `nix copy`, активация — root-юнитом `nixtache-apply.service` (probe+rollback
> внутри, §8.5), который deploy-юзер триггерит по polkit. См. `direct-deploy/02-action.md`.

```
mode ← из ветки (§7.1): main → switch, иначе dry-activate
1. configs ← nix flake show --json | jq '.nixosConfigurations | keys[]'
2. map     ← $NIXTACHE_DEPLOY_TARGETS  (JSON из env: {name,host,sshUser,sshPort,
              method,system,tags,hasKey})
3. for cfg in configs:
     t = map.${cfg} or ∅
     # --- фильтры опциональности (R1) ---
     if t == ∅:           print "skip: нет записи в карте";   continue
     if !t.hasKey:        print "skip: не задан deploy-ключ"; continue
     if !t.enable:        print "skip: enable=false";         continue

     # --- probe (R5): короткий SSH-пинг тем же ключом ---
     key = $CREDENTIALS_DIRECTORY/deploy_ssh_${cfg}
     ssh -o ConnectTimeout=10 -o BatchMode=yes -i $key \
         -p ${t.sshPort} ${t.sshUser}@${t.host} true \
       || { warn "хост недоступен — пропускаю"; continue; }   # не роняем CI

     # --- activate (mode + method) ---
     case t.method in
       live)     _liveApply "$cfg" "$t" "$mode" "$key" ;;     # ниже
       ab-image) _abImage  "$cfg" "$t" "$mode"      ;;        # §8, 06-ab-image.md
     esac
```

`_liveApply` (method = "live", default):

```
_liveApply(cfg, t, mode, key):
  # 1. build toplevel на раннере (sandbox; HAS_SANDBOX_CAP=0 → --no-sandbox)
  P=$(nix build --no-link --print-out-paths .#nixosConfigurations.${cfg}.config.system.build.toplevel)
  if mode == "dry-activate":                              # PR-предпросмотр — без мутации
     nixos-rebuild dry-activate --flake .#${cfg} \
        --target-host ${t.sshUser}@${t.host} --use-remote-sudo ${t.extraOptions}
     return
  # 2. copy closure на цель (deploy-юзер, allowed-users NixOS default)
  nix copy --to ssh://${t.sshUser}@${t.host} "$P"
  # 3. drop pointer + trigger root apply-unit (polkit авторизует только start)
  ssh -i $key -p ${t.sshPort} ${t.sshUser}@${t.host} "
       echo '$P' > /var/lib/nixtache/pending-system &&     # deploy-юзер пишет (group nixtache-deploy)
       systemctl start nixtache-apply.service"             # синхронно: oneshot блокирует до финиша
  # exit code SSH = exit code apply-unit:
  #   apply.service: set profile → switch → probe criticalUnits → rollback on fail (§8.5)
  #   fail → джоба краснеет
```

> `dry-activate` остаётся на `nixos-rebuild` (он не мутирует, ему `--use-remote-sudo`
> OK для diff-only). `switch` идёт исключительно через apply-юнит — без sudo на
> deploy-юзере, только polkit на `systemctl start nixtache-apply.service`.

### 7.3. Сборка и доставка

`nix build` собирает `toplevel` **локально на раннере** (его nix-daemon + sandbox),
`nix copy --to ssh://...` толкает closure на цель, root-юнит активирует. Это:

- переиспользует уже собранные в `nix-check` пути (binary cache на раннере);
- не требует ставить nix-инструменты на цель сверх `nix` (`nix copy` пишет через
  nix-daemon; `switch-to-configuration`/`nix-env` выполняет root-юнит на самой цели);
- для совпадающей с раннером архитектуры — нативно. **Cross-arch в скоупе** (не
  только `x86_64`): arch цели берётся из
  `nixosConfigurations.<name>.config.nixpkgs.hostPlatform`, механизм сборки —
  binfmt-эмуляция на runner-host (`boot.binfmt.emulatedSystems`, приоритетный
  путь). `--build-host`/`remoteBuild` убраны (S4). См. §11.9 и
  `direct-deploy/07-cross-arch.md`.

### 7.4. Раннер, на котором это бежит

Маршрутизация — через **labels уже существующих instances** (механизм
реализован, изобретать ничего не надо): каждый `instances.<name>` модуля
становится отдельным `gitea-runner-<name>` со своими `labels` + `tokenFile`
(`modules/runner/instances.nix`), джоба рутируется по `runs-on: <label>` — так
потребитель уже подключил `default` (`nixos:host`) и `test` (`test:host`) в
`server/services/forgejo-runner.nix`.

- **desktop/laptop деплой** — на существующем `default` (label `nixos:host`,
  тот же контейнер), как `nix-check`. `method = "live"` (default).
- **server деплой** — `method = "ab-image"` (§8): CI (в контейнере) build+stage+flag
  → host `systemd-sysupdate` пишет неактивный слот → reboot по idle раннеров.
  Деплоер живёт (слот A не тронут), бегущие джобы не рвутся.

«Отдельный runs-on» — это просто ещё один label по уже работающей схеме.

---

## 8. Chicken-and-egg сервера → A/B image (systemd-sysupdate)

**Проблема.** CI-раннер живёт в NixOS-контейнере на сервере. Live-deploy сервера
(`method = "live"` — root-юнит `nixtache-apply.service`) из контейнера
перезапускает этот контейнер и убивает джобу. Один деплоер не может безопасно
применить live-switch к хосту, в контейнере которого сам бегёт.

**Решение — A/B image-update через `systemd-sysupdate`** (per-target флаг
`method = "ab-image"`, см. §5). Деплой = **запись нового образа в неактивный
слот**, а не live-switch. Деплоер (контейнер на слоте A) переживает запись (слот
A не тронут); cutover = ребут в слот B, атомарно, с boot-counting rollback.

> Live-активация (`method = "live"`, root-юнит) **не умеет** писать A/B-слоты.
> Поэтому `ab-image` — отдельная ветка action'а: CI **stage'ит** образ локально
> + взводит флаг; host-овый `systemd-sysupdate` (не контейнер) пишет неактивный
> слот; reboot **асинхронный**, по idle раннеров (не рвёт джобы). HTTPS для
> self-update не нужен. Детально — `direct-deploy/06-ab-image.md`.

### 8.1. Разделение по классам машин

| Класс | `method` | Почему |
|---|---|---|
| desktop/laptop | `live` (default) | их switch не убивает деплоер; root-юнит `nixtache-apply.service` применяет сразу (без ребута), zero prep |
| **server (nixtache-host)** | `ab-image` | chicken-and-egg: пишем неактивный слот, деплоер (контейнер) живёт |

Любую машину можно перевести на `ab-image` (атомарность + image-rollback), но это
opt-in с consumer-prep (`06-ab-image.md` §1–7). Дефолт `live` ничего из этого
не требует.

### 8.2. SPOF / rollback

Forgejo крутится в одном экземпляре на сервере (HA отклонён). Если сервер лежит
целиком — CI не запустится; это принимается. Rollback:
- `ab-image`-машины → boot-counting (N1) + Tier-0 `boot-complete.target` по
  `criticalUnits` (§8.5);
- `live`-машины → native generations + Tier-1 auto-revert внутри
  `nixtache-apply.service` (§8.5).

### 8.3. Routine-обновления сервера

Помимо CI-`ab-image`, сервер крутит `system.autoUpgrade` (host-level таймер) как
автономный дефолт (§1 «Модель доставки») — chicken-and-egg не имеет (бежит на
хосте, не в контейнере). `ab-image` — CI-ускоритель + атомарность поверх.

### 8.5. Многоуровневый health-check + auto-rollback (для **всех** таргетов)

> Раньше это была не-цель («ручной `--rollback`»). Переведено в скоуп: rollback
> настраивается на **каждой** машине-таргете, не только на хосте nixtache.

Восстановление управляется **списком критичных юнитов** (`criticalUnits`) —
настраиваемым per-target. Если хоть один не поднялся после boot/switch → откат.
Список живёт в **конфиге самого таргета** (единый источник правды), а не в карте
раннера. AmneziaWG — канонический обязательный элемент для всех машин («все
точно должны амнезию поднять»); поверх него каждая машина докидает своё
(forgejo/контейнер на хосте nixtache, и т.п.).

**Приёмный модуль `nixtache.nixosModules.deploy-target`** (новый, импортируется
в конфиг **каждого** таргета):

```nix
services.nixtache.deploy-target = {
  healthCheckTimeout = 300;           # сек (5 мин) — некоторые машины грузятся долго; настраивается per-target
  criticalUnits = [
    "amneziawg-wg0.service"           # универсально — для всех машин
    # на хосте nixtache добавляются потребителем:
    # "forgejo.service" "nixos-container@runner.service"
  ];
};
```

Два уровня отката (nixtache) + bootCounting как consumer-side опция (N1):

**Tier 0 — штатный, service-level при загрузке (приёмный модуль).**
Приёмный модуль генерирует oneshot `nixtache-health-check.service`, ordered
`Before=boot-complete.target`, который в окне `healthCheckTimeout` ждёт
`systemctl is-active --wait <unit>` для каждого `criticalUnits`. Если хоть один
не активен → oneshot fail → `boot-complete.target` не достигнут → благословения
(`systemd-bless-boot`) нет. Дополнительно можно включить
`systemd-boot-check-no-failures.service`. Покрывает **service-breaking**
изменения. Чтобы отсутствие благословения привело к **откату generation** (а не
просто к неотметке), consumer включает bootCounting (см. ниже) — это его scope.

**Tier 1 — живой rollback сразу после `switch`, без ребута (внутри apply-юнита).**
Root-юнит `nixtache-apply.service` (запущенный deploy-юзером через polkit, §7.2)
после `nix-env --set <closure>` + `switch-to-configuration switch` **локально**
опрашивает `systemctl is-active --wait <unit>` для каждого `criticalUnits` (тот
же источник правды, что у Tier 0) в окне `healthCheckTimeout`. При fail —
откатывает system profile к pre-apply closure (`nix-env --set <prev>` +
`switch-to-configuration switch`) и выходит с `exit 1` → `systemctl start`
возвращяет ненулевой код по SSH → джоба краснеет. Немедленный откат, без ребута.
Probe крутится **на самой цели как root** (через dbus/systemctl) — поэтому
работает даже если новый конфиг сломал `sshd` (deploy-юэеру SSH уже не нужен,
юнит уже запущен). Детали — `doc/specs/direct-deploy/05-rollback.md` (Tier-1).

> V2: Tier-1 ранее планировался через deploy-rs `magicRollback` (`--checks`), но
> флага `--checks` не существует, а nodeless ad-hoc вызов deploy-rs невозможен.
> Поэтому probe перенесён внутрь root-юнита — чище, не зависит от deploy-rs, и
> устойчив к падению sshd (B1).

**Consumer-side: bootCounting (был Tier 0 — вынесен в scope consumer'а, N1 решено).**
`boot.loader.systemd-boot.bootCounting.enable = true` — Automatic Boot
Assessment: generation пишётся с boot-счётчиком, `systemd-bless-boot` метит
«good» при достижении `boot-complete.target`, обнуливший счётчик → грузится
прошлая. Покрывает **boot-breaking** изменения (kernel/initrd/hardware) и
превращает Tier 0 (отсутствие bless) в реальный откат generation на следующей
загрузке. **Решение включить — за consumer'ом**, per-target (требует systemd-boot;
на GRUB недоступно). Реализация consumer-стороны делегирована другим агентам.

| Уровень | Что ловит | Механизм | Где настраивается | Когда срабатывает |
|---|---|---|---|---|
| Tier 0 | грузится, но критичный юнит упал | `boot-complete.target` gated oneshot по `criticalUnits` → нет bless | приёмный модуль (`criticalUnits`, `healthCheckTimeout`) | на следующей загрузке |
| Tier 1 | живой `switch` сломал сервисы | `nixtache-apply.service`: set+switch → probe `criticalUnits` локально → `nix-env --set <prev>` (auto-revert) | `criticalUnits` цели (приёмный модуль) | немедленно в джобе |
| *(consumer)* | не грузится ядро/initrd/hardware | `systemd-boot` boot counting (N1) | consumer: `boot.loader.systemd-boot.bootCounting` | после N failed boots |

---

## 9. Безопасность и rollback

### 9.1. Защита `mode: switch`

> **Ресёрч (Q3 закрыт):** у Forgejo Actions **нет** GitHub-фичи `environment:`
> с required-reviewers — её нет в workflow-синтаксисе v15.0 (LTS), и по
> codeberg.org/forgejo/discussions#440 фича не реализована (завязана на
> Deployments + Rules, которых в Forgejo нет). Поэтому гейт — это **PR
> review/merge** (mode по ветке, §7.1), а не environment-protection.

`switch` меняет работающую систему. Гейт — **PR** (review + merge), не ручной
approval каждого деплоя; безопасность даёт auto-rollback (§8.5). Режим — по
ветке (см. §7.1), без inputs:

- **PR (≠ `main`)** → `dry-activate`: предпросмотр диффа в PR, мутации нет.
  Ревьюер видит дифф до merge — это и есть гейт.
- **`main`** → `switch`: merge применяет конфиг на машинах сразу после того,
  как сборочный stage (`nix-check`) позеленел. Быстрая доставка.
- **Триггер** — `on.workflow_run` на успех `nix-check.yml` (или `needs: <build>`
  в одном пайплайне): деплой стартует **когда всё собралось**.
- **Сериализация:** `concurrency.group: deploy-<target>` + `cancel-in-progress:
  false`.
- **Ручной `workflow_dispatch`** (без inputs) — опц., для форсирования вне
  триггера; режим всё равно по ветке запуска.

Ролей «server/desktop/laptop» нет — только таргет-машины (примеры ниже).

### 9.2. Привилегии deploy-пользователя (V2: polkit + root-юнит, без sudo)

> **Раньше (deploy-rs + sudo):** deploy-юзеру давали NOPASSWD sudo на набор команд
> активации (sudo/doas/sudo-rs/run0 — выбор таргета). **V2:** вся активация
> выполняется root-юнитом `nixtache-apply.service`, который deploy-юзер только
> **триггерит** через polkit (`systemctl start`). Никакого escalation-тула на
> deploy-юзере нет вообще — polkit + systemd универсальны («он везде есть»),
> выбор doas/sudo/sudo-rs исчез как класс проблем. Это и есть максимально
> root-less решение: deploy-юзер не может запустить произвольную команду как root
> — только стартовать один конкретный, аудитируемый юнит.

**Что нужно deploy-пользователю (всего три минимума):**
- **SSH-вход**: `openssh.authorizedKeys` = публичный ключ деплоя;
- **доступ к nix-daemon** (дефолт NixOS, `nix.settings.allowed-users = ["*"]`) —
  чтобы цель приняла closure (`nix copy --to`);
- **write в `/var/lib/nixtache/`** (через членство в группе `nixtache-deploy`) —
  чтобы положить pointer-файл `pending-system`;
- **polkit-авторизация на `systemctl start nixtache-apply.service`** —
  правило `org.freedesktop.systemd1.manage-units` для `verb=start` и ровно этой
  одной единицы. Ни stop, ни restart, ни других юнитов.

Всё остальное (set profile, `switch-to-configuration switch`, probe, rollback)
делает сам root-юнит. deploy-юзер **не получает** sudo/doas/run0 ни на что.

**Модуль владеет разрешениями и ассертит.** Приёмный модуль
`nixosModules.deploy-target` опцию:

```nix
services.nixtache.deploy-target.deployUser = {
  name          = "nixos-deploy";    # пользователь активации на ЭТОЙ машине
  authorizedKey = "ssh-ed25519 …";   # публичный ключ (строка)
  autoProvision = true;              # см. ниже
};
```

- `autoProvision = true` (дефолт): модуль **сам** создаёт пользователя
  (`isNormalUser`), ставит `authorizedKeys`, включает его в группу
  `nixtache-deploy` и генерирует polkit-правило под его имя.
- `autoProvision = false`: пользователя/ключ управляет consumer; модуль **всё
  равно** добавляет его в группу + генерирует polkit-правило (разрешения —
  забота модуля) **и ассертит** (`assertions`), что `users.users.${name}`
  существует. Не найдено → eval падает с понятным сообщением.

> polkit и `nixtache-apply.service` создаёт сам модуль (`force security.polkit.enable = true`).
> `sudo`/`sudo-rs`/`doas`/`run0` модулю **не нужны** — даже если таргет их не
> имеет, активация работает (systemd + polkit есть везде).

> Для `method = "ab-image"` привилегии deploy-юзера те же (SSH + polkit/SSH на
> триггер sysupdate) — см. `direct-deploy/06-ab-image.md`.

### 9.3. Rollback

**Авто-rollback спроектирован для всех таргетов** (§8.5): два уровня nixtache —
Tier-0 `boot-complete.target` gated по `criticalUnits` + Tier-1 живой откат
внутри `nixtache-apply.service` (set+switch → probe → `nix-env --set <prev>` при
fail); плюс bootCounting как consumer-side опция (N1) для boot-breaking случаев.
Список критичных юнитов (AmneziaWG — обязательный для всех + per-target)
настраивается через приёмный модуль `nixtache.nixosModules.deploy-target`.

**Ручной fallback** (когда авто не сработало / точечный откат):

```bash
ssh nixos-deploy@<host> \
  sudo nixos-rebuild switch --rollback
  # либо: sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <N>
```

Для `ab-image`-машин (server) дополнительная страховка — boot-counting (N1):
сломанный слот не доходит до `boot-complete.target` → откат к предыдущему слоту.
Tier-1 (probe+rollback внутри `nixtache-apply.service`) — для `live`-машин (N5).

---

## 10. Артефакты реализации в `nixtache`

| Артефакт | Назначение | Статус |
|---|---|---|
| `modules/runner/deploy.nix` | Опции `deploy.targets.<name>` + `LoadCredential`/`envs` wiring (merge в тот же контейнер) | НОВОЕ |
| `modules/runner/types.nix` | `deployTargetType` (подмодуль выше; `method = "live"\|"ab-image"`) | НОВОЕ |
| `modules/runner/instances.nix` | `_extraRunnerEnvs` агрегатор (S1) — envs из подмодулей в `runner.envs` | правка |
| `modules/deploy-target/` → `nixosModules.deploy-target` | **Приёмный модуль** (импортируется каждым таргетом): `criticalUnits`, `healthCheckTimeout`, `deployUser`; **`nixtache-apply.service` (root: set+switch+probe+rollback, Tier-1 §8.5)** + polkit-правило + `nixtache-deploy` group + pointer-dir; `nixtache-health-check.service` (`Before=`+`RequiredBy=` `boot-complete.target`) — Tier 0. bootCounting — consumer-scope (N1) | НОВОЕ |
| `.forgejo/workflows/deploy.yml` | Reusable workflow `on: workflow_call` + `workflow_run` (опц. `workflow_dispatch` без inputs) (§7) | НОВОЕ (заменяет стаб из migration-plan §6) |
| `.forgejo/actions/deploy-target/` | Composite-action (V2): discovery → probe → `_liveApply` (`nix build` → `nix copy --to` → pointer + `systemctl start nixtache-apply.service`) / `_abImage`; `HAS_SANDBOX_CAP`→`--no-sandbox` | НОВОЕ |
| `tests/runner.nix` | + сценарии: карта пуста / карта с ключами / `enable=false` / `sshPrivateKey=null` / `method="ab-image"` / `method="live"` default / `_extraRunnerEnvs` агрегация | правка |
| `tests/deploy-target.nix` | приёмный модуль: apply-юнит wired + polkit + probe/rollback в скрипте, `criticalUnits` wired в oneshot, `healthCheckTimeout` default, `autoProvision=false` assertion | НОВОЕ |
| `packages.optionsMarkdown` | авто-включит новые опции (`services.nixtache.runner.deploy.*` + `services.nixtache.deploy-target.*`) | без правок |
| `README.md` / `AGENTS.md` | раздел «Deploy» со ссылкой на спеку | правка |

> **V2:** deploy-rs / `nixtache.lib.mkDeployNodes` / `activate.custom` / `transport`
> поле — **убраны**. Активация исключительно через root-юнит `nixtache-apply.service`
> + polkit. См. `REVIEW-ISSUES.md` §«V2-пивот».

### Consumer-side артефакты (`nixos-configuration`)

| Артефакт | Назначение |
|---|---|
| `server/services/deploy-keys.nix` | sops-deploy-ключи + наполнение `deploy.targets` (пример в §6) |
| `secrets/deploy-keys/{desktop,laptop}.ed25519` | зашифрованные ключи (age) |
| `common/deploy-target.nix` | `imports = [ nixtache.nixosModules.deploy-target ]` + universal `criticalUnits` (AmneziaWG) + `deployUser` (модуль сам провижинит юзера + polkit + apply-юнит) |
| `.forgejo/workflows/deploy.yml` | тонкая обёртка: `jobs.deploy.uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main` |

---

## 11. Этапы реализации

1. **Контракт модуля** — `deployTargetType` + опция `deploy.targets` +
   `deploy.nix` (env `NIXTACHE_DEPLOY_TARGETS` + `LoadCredential`) + S1-рефактор
   `instances.nix` (`_extraRunnerEnvs`); тесты в `tests/runner.nix`. ✅ (Batch A)
2. **Приёмный модуль `deploy-target`** — `nixtache-apply.service` (root: set +
   switch + probe `criticalUnits` + rollback) + polkit на `systemctl start` +
   `nixtache-health-check.service` (Tier-0); `deployUser` provisioning (без sudo);
   тесты `tests/deploy-target.nix`. ✅ (Batch B)
3. **Action `deploy-target`** — discovery + probe + `_liveApply` (`nix build` →
   `nix copy --to` → pointer + `systemctl start nixtache-apply.service`) /
   `_abImage`; все skip-ветки = `continue`, не `exit 1`; `HAS_SANDBOX_CAP`-aware.
4. **Workflow `deploy.yml`** — без inputs, mode по ветке (§7.1), calls action.
5. **Consumer wiring (nixos-configuration)** — `deploy-keys.nix`, ключи в sops,
   `common/deploy-target.nix` (импорт приёмного модуля + `criticalUnits` +
   `deployUser`).
6. **Дымовой тест** — открыть PR → `dry-activate` автофайрится → проверить,
   что desktop/laptop пройдут discovery+probe и покажут diff без активации.
7. **`mode: switch`** — merge PR в `main` → `switch` автофайрится (§7.1, §9.1).
   Tier-1 probe+rollback уже вшит в `nixtache-apply.service` (Batch B); consumer
   включает bootCounting (N1) для boot-breaking случаев.
8. **Server A/B image** — `method = "ab-image"` для `server`; action build+stage+flag
   → host `systemd-sysupdate` (idle-gated reboot) (§8, `direct-deploy/06-ab-image.md`).
   Consumer-prep: repart+UKI+sysupdate+boot-counting+Forgejo-token.
9. **Cross-arch** (подзадача) — arch **не хардкодится**, выводится из
   `nixpkgs.hostPlatform`/`system` декларации (рабочий набор сейчас:
   `x86_64-linux`, `aarch64-linux`):
   - **9a.** `rebuild-configurations` + `rebuild-devshells`: собирать то, что
     **заявлено** в конфиге/devShell (явный `system`). Cross-arch опирается на
     `boot.binfmt.emulatedSystems` хоста-раннера (настраивает потребитель,
     унифицированно). Сборка под незаявленную/недоступную arch → **fail CI**
     (и для `nixosConfigurations`, и для `devShells` — там `system` тоже явный).
   - **9b.** `deploy-target`: cross-arch сборка closure — через binfmt на
     runner-host (приоритет). Поля `buildHost`/`--build-host`/`remoteBuild` убраны
     (S4). Детали — `direct-deploy/07-cross-arch.md`.
   - **9c.** Тесты `tests/runner.nix`: цель `aarch64-linux`; `buildHost` поле
     **отсутствует** в JSON (assert); `boot.binfmt.emulatedSystems` на раннере.

---

## 12. Открытые вопросы (v3 → V2)

Раунд v2 (Q1–Q9) закрыт решениями пользователя:

- **A. Server self-update:** `method = "ab-image"` (systemd-sysupdate A/B) —
  решает chicken-and-egg (пишем неактивный слот, деплоер живёт); HA Forgejo
  отклонён. desktop/laptop — `method = "live"` (default, root-юнит). (Q1/Q2 → §8,
  `direct-deploy/06-ab-image.md`).
- **B:** native generations, без over-engineering (Q3 → §8.3).
- **C:** фича = **доставка дериваций сразу после успешной сборки** (зелёный
  `nix-check`, не ждём `autoUpgrade`); **mode по ветке** — PR (≠ `main`) →
  `dry-activate`, `main` → `switch`; **PR = гейт** (review/merge), inputs
  убраны; согласовано с `autoUpgrade` (тянет только `main`) (Q4/Q5 → §1 «Модель
  доставки», §7.1, §9.1).
- **D:** cross-arch через binfmt на хосте, arch не хардкодится, derive из
  конфига; fail CI при отсутствии эмуляции; devShells — так же (Q6/Q7/Q8 → §11.9).
- **E:** одна deploy-key пара на хост (Q9 → §6).

### Новые вопросы (v3)

| Q | Вопрос | Дефолт-рекомендация |
|---|---|---|
| **N1** ✅ | bootCounting — **решено**: вынесен в scope consumer'а (per-target, требует systemd-boot); на GRUB-хостах недоступно — откат только через Tier 0/1. Реализация consumer-стороны делегирована другим агентам | — |
| **N2** ✅ | health-probes — **решено**: только systemd-юниты (`criticalUnits`). HTTP-probes отложены. Состав: AmneziaWG для всех + per-target (forgejo/контейнер на хосте nixtache) | — |
| **N3** ✅ | Пороги — **решено**: `healthCheckTimeout` = **300с (5 мин)** дефолт (некоторые машины грузятся долго), **настраиваемое** per-target; `boot.uki.tries` = 3 (consumer-scope) | — |
| **N4** ✅ | Живой Tier-1 — **обязателен** (немедленный откат в джобе, чтобы CI краснел сразу); Tier 0 — service fails на загрузке | — |
| **N5** ✅ (V2) | Tier 1 — **решено (V2-ревизия)**: probe `criticalUnits` + rollback выполняет сам root-юнит `nixtache-apply.service` (set+switch → probe → `nix-env --set <prev>` при fail). **deploy-rs выкинут** целиком — флага `--checks` не существовало (B1), nodeless ad-hoc вызов невозможен (B2). Probe крутится на цели локально → устойчив к падению sshd. Детали — `doc/specs/direct-deploy/05-rollback.md` | — |
| **N6** ✅ (V2) | Transport активации — **решено (V2-ревизия)**: поле `transport` **убрано**. Единственный путь — root-юнит `nixtache-apply.service` + polkit (без sudo/doas/run0). Выбор escalation-тула исчез как класс проблем («решаем через systemd — он везде»). См. §9.2 | — |

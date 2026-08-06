# 01 — Контракт карты целей

> Этап 1 из `0001` §11. Кодовая детализация §4/§5 `0001`.
> **Статус:** 📝 черновик имплементации.

## Что строим

NixOS-опция `services.nixtache.runner.deploy.targets.<name>` на runner-модуле
(ставится в контейнерном `default`/`test`; ab-image для server — отдельная
ветка action'а, см. `06-ab-image.md`). Карта:
- сериализуется в env `NIXTACHE_DEPLOY_TARGETS` (чистые данные, без секретов);
- ключи монтируются через `LoadCredential` (один на цель).

Имя атрибута `<name>` **совпадает** с `nixosConfigurations.<name>` — по нему
discovery сопоставляет конфиг и цель.

## `deployTargetType` (`modules/runner/types.nix`)

```nix
deployTargetType = mkSubmodule {
  options = {
    enable = mkEnableOption "deploy to this target" // { default = true; };

    host = mkOption {
      type = types.str;
      description = "Адрес машины: LAN/VPN/публичный IP / DNS. config → host.";
    };

    sshUser = mkOption {
      type = types.str;
      default = "nixos-deploy";
      description = "SSH-пользователь транспорта. Должен совпадать с deployUser.name "
                 ++ "приёмного модуля (04-consumer-wiring.md §9.2).";
    };

    sshPort = mkOption {
      type = types.port;
      default = 22;
      description = "Нестандартный SSH-порт.";
    };

    method = mkOption {
      type = types.enum [ "live" "ab-image" ];
      default = "live";
      description = "Как обновлять цель: `live` (default — nix copy + root-юнит "
                 ++ "nixtache-apply.service по polkit) или `ab-image` (A/B-слот "
                 ++ "через systemd-sysupdate — chicken-and-egg хоста nixtache). "
                 ++ "ab-image требует consumer-prep (06-ab-image.md).";
    };

    # V2: transport убран — активация всегда через root-юнит + polkit
    # (без sudo/doas/run0). См. 0001 §9.2.

    sshPrivateKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Приватный deploy-ключ. Обязателен для обоих method: live (nix copy + SSH-триггер apply-юнита), ab-image (SSH-триггер sysupdate).";
    };

    sshPublicKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Публичный ключ (опц., для known_hosts/проверки).";
    };

    system = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Arch цели. null → derive из nixpkgs.hostPlatform конфига. Cross-arch — 07.";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Доп. флаги (напр. --no-substitute-on-target для nix copy).";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Метки целей (документация/фильтрация).";
    };

    timeout = mkOption {
      type = types.ints.positive;
      default = 240; # минут
      description = "Per-target таймаут сборка+активация.";
    };
  };
};
```

> `mode` убран — режим определяется веткой (`03-workflow.md`), не per-target.
> `transport` убран (V2) — активация всегда через root-юнит `nixtache-apply.service`
> + polkit, выбора escalation-тула нет.
> `buildHost` убран (S4) — cross-arch сборка идёт через
> `boot.binfmt.emulatedSystems` на раннере (`07-cross-arch.md`), без отдельного поля.

## `deploy.nix` wiring (`modules/runner/deploy.nix`)

Мержится в тот же контейнер (`default`/`test`).

> **S1 (решено):** агрегатора envs в `instances.nix` сейчас нет — `runner.envs`
> строится inline. Поэтому **сначала рефакторим `instances.nix`**: выносим опцию
> `services.nixtache.runner._extraRunnerEnvs` (тип `attrsOf str`), подтягиваем
> её в `runner.envs` через `mkMerge` (вместе с уже захардкоженными
> `NIXTACHE_*_GIT_USER`/`HAS_SANDBOX_CAP`). Тогда любой подмодуль (deploy.nix и
> будущие) дописывает свой env-ключ без правки `instances.nix` и без
> дублирования.

```nix
{ config, lib, ... }:
let
  cfg = config.services.nixtache.runner.deploy;
  typesT = import ./types.nix { inherit lib; };

  # JSON без секретных путей — только то, что уходит в env джобы.
  targetJSON = builtins.toJSON (lib.mapAttrs (name: t: {
    inherit name;
    inherit (t) host sshUser sshPort method transport system tags timeout;
    hasKey = t.sshPrivateKey != null;
  }) cfg.targets);
in {
  options.services.nixtache.runner.deploy.targets = mkOption {
    type = types.attrsOf typesT.deployTargetType;
    default = {};
    description = "Карта целей deploy: config → host → creds.";
  };

  config = mkIf (cfg.targets != {}) {
    # 1) карта → env (через агрегатор _extraRunnerEnvs → instances.nix вливает в runner.envs)
    services.nixtache.runner._extraRunnerEnvs.NIXTACHE_DEPLOY_TARGETS = targetJSON;

    # 2) ключи → LoadCredential (один bind-mount на цель)
    containers.${config.services.nixtache.runner.containerName}.bindMounts =
      lib.mapAttrs' (name: t: lib.nameValuePair "deploy_ssh_${name}" {
        mountPoint = "/var/secrets/runner/deploy/${name}/id_ed25519";
        hostPath = t.sshPrivateKey;
        isReadOnly = true;
      }) (lib.filterAttrs (_: t: t.sshPrivateKey != null) cfg.targets);
  };
}
```

> Рефактор `instances.nix`: добавить `options.services.nixtache.runner._extraRunnerEnvs`
> (`attrsOf str`, `default = {}`, internal), в `config` к существующему
> `runner.envs`-литералу добавить `// cfg._extraRunnerEnvs` (или `mkMerge`).
> Существующие `NIXTACHE_*` ключи можно оставить inline или тоже перенести — на
> усмотрение имплементации, но публичный контракт `runner.envs` не меняется.

## Формат `NIXTACHE_DEPLOY_TARGETS` (env в джобе)

```json
{
  "desktop": {"name":"desktop","host":"10.13.37.3","sshUser":"nixos-deploy",
              "sshPort":22,"method":"live","system":null,
              "tags":["lan","vpn"],"timeout":240,"hasKey":true},
  "server":  {"name":"server","host":"10.13.37.1","sshUser":"nixos-deploy",
              "sshPort":22,"method":"ab-image","system":null,
              "tags":[],"timeout":240,"hasKey":true}
}
```

`sshPrivateKey` обязателен для обоих `method` (live: `nix copy` + SSH-триггер
apply-юнита; ab-image: SSH-триггер `systemd-sysupdate`). `hasKey: false` → action
skip (R1). `transport` в JSON **отсутствует** (V2 — единственный путь активации).

## Тесты (`tests/runner.nix`, +сценарии)

| Сценарий | Что asserts |
|---|---|
| карта пуста | env `NIXTACHE_DEPLOY_TARGETS` = `{}`, bindMounts нет |
| карта с ключами (desktop+laptop) | env JSON содержит обе, `hasKey:true`, 2 bindMounts с правильными hostPath |
| `sshPrivateKey=null` | в env `hasKey:false` → action skip (R1); bindMount НЕТ |
| `method="ab-image"` (server) | поле в JSON корректно; action идёт по ab-image-ветке (06) |
| `method="live"` (default) | default в JSON = `"live"`; transport в JSON отсутствует |
| `enable=false` | цель в env отсутствует (или помечена) → action skip |
| `_extraRunnerEnvs` агрегация (S1) | deploy.nix-ключ доходит до `runner.envs` |

Тесты — pure-evaluation (`nixosSystem` + assert на `config.*`), по образцу
существующего `tests/runner.nix`. Каждая новая опция + поведение покрыты (правило
nixtache: «каждая опция — тест»).

## Артефакты этапа

- `modules/runner/types.nix` — `deployTargetType` (`method = "live"|"ab-image"`;
  без `transport`, без `buildHost`).
- `modules/runner/deploy.nix` — НОВОЕ.
- `modules/runner/instances.nix` — **рефактор**: вынести `_extraRunnerEnvs`
  (S1), влить в `runner.envs`. Публичный контракт не меняется.
- `modules/runner/default.nix` — `imports += [ ./deploy.nix ]`.
- `tests/runner.nix` — +сценарии выше, +сценарий `_extraRunnerEnvs` агрегируется
  в `runner.envs`.

## Зависимости / следующие этапы

- → `02-action.md` (action читает env + ключи, выполняет алгоритм `0001` §7.2).
- → `04-consumer-wiring.md` (consumer наполняет `targets` + приёмный модуль).

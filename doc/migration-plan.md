# План миграции CI/CD: `nixos-configuration` → `nixtache`

> **Статус:** план согласован (Q1–Q5 решены)
> **Дата:** 2026-08-03
> **Цель:** вынести CI/CD-инфраструктуру (раннер Forgejo, бинарный кэш, кастомный nix-daemon,
> workflows, actions) из репозитория `nixos-configuration` в **переиспользуемый, vendor-агностичный**
> проект `nixtache`, который любой проект сможет подключить через flake-input **без форка**.
>
> **Ключевой принцип:** `nixtache` **не хранит** секреты и **не хардкодит** проектно-специфичные
> значения (домены, URL инстансов, ключи). Всё проектно-специфичное поставляется потребителем через
> опции модуля. GitLab-runner в scope **не входит** (остаётся в `nixos-configuration`).

---

## 1. Контекст

`nixos-configuration` сегодня совмещает три ответственности:

1. Описание целевых машин (desktop / laptop / server).
2. Инфраструктуру CI/CD (раннер Forgejo, бинарный кэш, кастомный nix-daemon; gitlab-runner вынесен из scope).
3. Сами CI-скрипты (`.forgejo/workflows/*`, `.forgejo/actions/*`).

`nixtache` забирает на себя пункты **2** и **3**, оставив `nixos-configuration` «чистой»
декларацией машин. `nixtache` — **переиспользуемый flake-модуль**, который:

- экспортирует NixOS-модуль раннера (`nixosModules.forgejo-runner`) для подключения через flake-input;
- содержит переиспользуемые Forgejo-actions и reusable-workflows;
- предоставляет **абстракцию поставки секретов** (path-based ядро + provider-пресеты `sops`/`vault`/`systemd`),
  **не храня** секреты сам;
- резервирует контракт деплоя (реализация — отдельной задачей).

---

## 2. Что переносится

### 2.1. Модули раннеров (NixOS-инфраструктура)

#### 2.1.1. `forgejo-runner` — ядерный модуль

**Источник:** `nixos-configuration/server/services/forgejo-runner.nix` (~323 строки)

Назначение и состав:

- **NixOS-контейнер** `forgejo-runner` с `autoStart = true`.
  Лимиты хоста: `MemoryMax = 60G`, `MemoryHigh = 58G`, `TimeoutStartSec = 1d`.
- **SOPS-секреты** (4 шт.):
  - `forgejo-token-env` ← `secrets/actions.env` (dotenv, режим `0444`);
  - `forgejo-private-key` ← `secrets/fbot.key.enc` (binary);
  - `forgejo-public-key` ← `secrets/bot-keys.yaml` → `public-key`;
  - `cache-private-key` ← `secrets/bot-keys.yaml` → `priv-cache-key`.
- **bind-mounts** в контейнер: 4 секрета (только чтение) + `/srv` → `/srv/bincache` (запись).
- **`services.gitea-actions-runner`**, инстанс `default`:
  - `label = [ "nixos:host" ]`;
  - host-пакеты: `bash coreutils curl gawk gitMinimal git-lfs gnused wget nix nodejs jq openssh nixos-rebuild`;
  - таймауты `runner.timeout = shutdown_timeout = "72h"`, debug-логирование;
  - `tokenFile` ← смонтированный секрет.
- **Бинарный кэш** `nix-serve-ng` (порт `server_secrets.network.ports.serve`), ключ — `cache-private-key.pem`.
- **Кастомный nix-daemon** (нестандартная инфраструктурная логика, переносится целиком):
  - `nix-daemon-custom` — запускает `nix-daemon` с `BindPaths=/srv/nix:/nix`, высоким `OOMScoreAdjust`, делегированием;
  - `nix-daemon-storage` — oneshot, копирует весь store в `/srv/nix` с ретраями каждые 5 сек;
  - `systemd.sockets.nix-daemon-custom` — слушает `/srv/nix/var/nix/daemon-socket/socket`;
  - зависимость `gitea-runner-default` и `nix-serve` от `nix-daemon-custom.service`.
- **nginx vhost** `bincache.zinzaguras.ru` (ACME, forceSSL, proxy → `nix-serve`).
- **Конфигурация nix внутри контейнера:** gc/optimise по расписанию, `experimental-features`,
  `substituters` (включая `bincache.zinzaguras.ru` и зеркала), `trusted-public-keys`,
  `max-jobs = 1`, `cores = 8`, `system-features` наследуется от хоста.
- **knownHosts** для `zinzaguras.ru` и `github.com` (несколько ключей); `openssh.enable = false`.

> Переносится в `nixtache` полностью, как `nixosModules.forgejo-runner`.
>
> **Важная правка (vendor-agnostic):** модуль параметризуется — все проектно-специфичные
> значения становятся опциями с дефолтами: URL инстанса Forgejo, домен и порт бинарного кэша,
> label раннера, host-пакеты, таймауты, лимиты ресурсов контейнера (`MemoryMax`/`MemoryHigh`/
> `TimeoutStartSec`), `knownHosts`, имя контейнера, параметры nix (`substituters`,
> `trusted-public-keys`, `max-jobs`, `cores`). **Секреты** (`token`, SSH-ключи бота, ключ кэша)
> задаются как `types.path` через `secrets.*` и **поставляются потребителем** (см. раздел 2.4 и Q4).
> Таким образом `nixtache` остаётся переиспользуемым без форка.

#### 2.1.2. ~~`gitlab-runner`~~ — ВЫНEСЕН ИЗ SCOPE

> **Решение (правка):** GitLab-runner в проекте не используется. Модуль
> `server/modules/gitlab-runner.nix` и сервис `server/services/gitlab-runner.nix`, а также
> `secrets/gitlab-runner.env` **остаются в `nixos-configuration` без изменений** (либо удаляются
> отдельной задачей). `nixtache` их не переносит. Фокус миграции — только `forgejo-runner`.

### 2.2. CI/CD workflows

**Источник:** `nixos-configuration/.forgejo/workflows/`

| Файл | Триггер | Что делает |
|---|---|---|
| `nix-check.yml` | `push`/`pull_request` → `main` | checkout(LFS) → ssh-setup → `nix flake metadata` → flake-validation → rebuild-configurations → rebuild-devshells → upload-artifact → failure-handler. Таймаут 4600 мин. |
| `update-flake.yml` | cron `0 4 * * 0` + `workflow_dispatch` | `nix flake update --commit-lock-file` с **SSH-подписанными коммитами** (`fbot`), валидация, сборка, `git push` по SSH в `code.zinzaguras.ru`. |

> **Внимание:** эти workflow жёстко привязаны к репозиторию `nixos-configuration`
> (собирают именно его `nixosConfigurations`/`devShells`). Решение о форме переноса
> (reusable workflows vs. тонкие обёртки в `nixos-configuration`, вызывающие actions из `nixtache`)
> фиксируется в разделе 6 (вопрос Q2).

### 2.3. Custom Actions

**Источник:** `nixos-configuration/.forgejo/actions/`

| Action | Назначение |
|---|---|
| `ssh-setup` | Копирует SSH-ключи из `$CREDENTIALS_DIRECTORY` (systemd `LoadCredential`), формирует `~/.ssh/config` для `code.zinzaguras.ru` (user `fbot`), настраивает `git config core.sshCommand`. |
| `flake-validation` | `nix flake check --show-trace --all-systems`. |
| `rebuild-configurations` | Через `nix flake show --json` перечисляет `nixosConfigurations`, собирает `.#nixosConfigurations.$c.config.system.build.toplevel` (логи в `artifacts/`). |
| `rebuild-devshells` | Для каждого `system` из inputs — `nix print-dev-env .#devShells.$system.$shell`. |

> Все 4 действия переносятся в `nixtache/.forgejo/actions/` и становятся переиспользуемыми.

### 2.4. CI-секреты → абстракция поставки (vendor-agnostic)

> **Решение Q4 (B).** `nixtache` **не хранит секреты** и не содержит `.sops.yaml`/`secrets/`.
> Модуль лишь **объявляет потребность** в секретах как `secrets.<name>: types.path`, а
> **потребитель** решает, как их доставить, через один из опциональных **provider-пресетов**
> (`sops` / `vault` / `systemd`) либо напрямую подсунув пути любого другого бэкенда.

#### 2.4.1. Логические секреты, нужные `forgejo-runner`

| Логическое имя в модуле | Назначение | Куда уходит в рантайме |
|---|---|---|
| `secrets.tokenFile` | токен регистрации Forgejo-раннера | `gitea-actions-runner.tokenFile` |
| `secrets.sshPrivateKey` | приватный SSH-ключ бота (push обратно в репо) | bind-mount в контейнер / LoadCredential |
| `secrets.sshPublicKey` | публичный SSH-ключ бота | bind-mount в контейнер |
| `secrets.cachePrivateKey` | приватный ключ бинарного кэша | `nix-serve.secretKeyFile` |
| *(будущее, Q3)* `secrets.deployKey` | SSH-ключ для деплоя на машины | агент деплоя |

#### 2.4.2. Исходные (проектные) файлы секретов в `nixos-configuration`

Эти файлы **остаются во владении потребителя** (`nixos-configuration/secrets/` или его Vault) и
`nixtache` о них не знает:

| Файл (текущий) | Тип | Логическое имя в модуле |
|---|---|---|
| `secrets/actions.env` | dotenv | `token` |
| `secrets/fbot.key.enc` | binary | `sshPrivateKey` |
| `secrets/bot-keys.yaml` → `public-key` | yaml | `sshPublicKey` |
| `secrets/bot-keys.yaml` → `priv-cache-key` | yaml | `cachePrivateKey` |
| ~~`secrets/gitlab-runner.env`~~ | — | *(вне scope, см. 2.1.2)* |

#### 2.4.3. Поддерживаемые бэкенды (поставщики)

| Бэкенд | Тип | Что даёт путь в NixOS |
|---|---|---|
| **sops-nix** | repo (age/PGP) | `config.sops.secrets.X.path` |
| **agenix** | repo (age) | `*.path` |
| **HashiCorp Vault** | внешний (API) | `vault-agent` template → статичный файл **ИЛИ** `numtide/systemd-vaultd` → `$CREDENTIALS_DIRECTORY/<key>` |
| **systemd LoadCredential** | host-managed | `/run/credentials/<svc>/<key>` |
| **Doppler / Infisical / cloud SM** | внешний SaaS | агент материализует `.env`/файлы → путь |
| **Forgejo CI variables** | workflow-level | `${{ secrets.X }}` (только для пайплайна, не для контейнера раннера) |

> **Проверено по Vault:** Vault не хранит секрет файлом в репо (как sops), а отдаёт его в рантайме
> через агент. Но на хосте агент **всегда материализует секрет в путь** — либо статичный файл
> (`vault-agent` template `destination`), либо `$CREDENTIALS_DIRECTORY` через `systemd-vaultd`
> (поддерживается Mic92 — автором sops-nix). Поэтому path-based контракт покрывает Vault без
> специальной магии в модуле.

#### 2.4.4. Provider-пресеты (опциональный сахар над path-based ядром)

```nix
# Вариант 1 — sops (текущая схема nixos-configuration)
nixtache.secrets.providers.sops = {
  enable = true;
  mapping = { token = "actions.env"; sshPrivateKey = "fbot.key.enc"; /* ... */ };
};

# Вариант 2 — Vault (systemd-vaultd)
nixtache.secrets.providers.vault = {
  enable = true;
  agent = "default";
  path  = "secret/forgejo";
  delivery = "credential";   # "credential" (systemd-vaultd) | "file" (vault-agent template)
  mapping = { token = "runner-token"; sshPrivateKey = "fbot-key"; /* ... */ };
};

# Вариант 3 — ручная подстановка путей (любой бэкенд, нулевая магия)
services.nixtache.forgejo-runner.secrets = {
  tokenFile       = config.sops.secrets.forgejo-token-env.path;          # sops
  sshPrivateKey   = "/run/vault-secrets/forgejo/fbot-key";               # vault-agent
  sshPublicKey    = "/run/credentials/forgejo-runner/fbot.pub";          # systemd
  cachePrivateKey = config.sops.secrets.cache-private-key.path;
};
```

> Ядро модуля (`secrets.*: types.path`) — это вариант A; пресеты — надстройка B, **не ломающая**
> совместимость: пресет лишь генерирует пути и объявления и подставляет их в `secrets.*`.

---

## 3. Что ОСТАЁТСЯ в `nixos-configuration`

- `server/services/forgejo.nix` + `server/modules/forgejo.nix` — сам **сервер Forgejo** (git-хост), не CI.
- `server/services/gitlab-runner.nix` + `server/modules/gitlab-runner.nix` + `secrets/gitlab-runner.env` — **остаются как есть** (вне scope миграции, см. 2.1.2).
- Общая инфраструктура сервера: `nginx.nix`, `anubis.nix`, `fail2ban.nix` и т.п. (от них зависит и хост, и раннер).
- Общий `.sops.yaml` (age-ключи машин) и пользовательские секреты (`amneziawg-*`, `yggdrasil.key.enc`, `matrix.yaml`, `common.yaml`, `actions.env`, `fbot.key.enc`, `bot-keys.yaml`) — остаются во владении потребителя; `nixtache` получает их как пути через provider-пресет (Q4=B).
- `devshells/` — определяются здесь, лишь **собираются** в CI.

---

## 4. Целевая структура `nixtache` (предварительная)

```
nixtache/
├── flake.nix                      # экспорт nixosModules + (опц.) deploy-контракт
├── modules/
│   └── forgejo-runner.nix         # ← server/services/forgejo-runner.nix (параметризованный)
├── secrets/                       # НЕ хранит секреты; содержит provider-пресеты
│   └── providers/
│       ├── sops.nix               # авто-wire sops.secrets.* → paths
│       ├── vault.nix              # vault-agent template | systemd-vaultd
│       └── systemd.nix            # LoadCredential paths
├── .forgejo/
│   ├── workflows/
│   │   ├── nix-check.yml          # reusable (on: workflow_call)
│   │   ├── update-flake.yml       # reusable (on: workflow_call)
│   │   └── deploy.yml             # заглушка контракта деплоя (раздел 6)
│   └── actions/
│       ├── ssh-setup/             # параметризованный (git-host, git-user, key-paths — inputs)
│       ├── flake-validation/
│       ├── rebuild-configurations/
│       ├── rebuild-devshells/
│       └── deploy-target/         # заглушка → реализация позже
└── doc/
    └── migration-plan.md
```

> **Секретов и `.sops.yaml` в `nixtache` нет** — модуль vendor-агностичен и переиспользуем.
> `instances/` убран: инстанс-значения теперь живут у потребителя, а не в библиотеке.

---

## 5. Открытые архитектурные вопросы

> Решаются отдельно (см. обсуждение вне документа).

- **Q1. ✅ РЕШЕНО (A).** `nixtache` — flake, экспортирующий `nixosModules.forgejo-runner` (gitlab-runner вне scope). `nixos-configuration` подключает его как `inputs.nixtache.nixosModules.forgejo-runner` (совпадает с существующим паттерном `secrets.nixosModules.*` / `sops-nix.nixosModules.*`). `nixtache` самодостаточен и валидируется собственным CI.
- **Q2. ✅ РЕШЕНО (B).** Логика пайплайна переезжает в `nixtache/.forgejo/workflows/*.yml` с триггером `on: workflow_call` (+ `workflow_dispatch`). В `nixos-configuration` остаются тонкие вызывающие файлы вида `jobs.check.uses: nixops/nixtache/.forgejo/workflows/nix-check.yml@main` (`secrets: inherit`). Reusable-workflow выполняется в контексте вызывающего репозитория, т.е. `actions/checkout` видит `nixos-configuration` — поведение эквивалентно текущему.
  - **Риск/имплементационная заметка:** разрешение путей к composite-actions (`./.forgejo/actions/X`) внутри cross-repo reusable-workflow зависит от того, как Forgejo подгружает контекст репозитория-владельца workflow. Требуется короткий спайк на версии Forgejo, развёрнутой на сервере, **до** реализации. При проблемах — fallback на явный `actions/checkout` репо `nixops/nixtache` и пути `./nixtache/.forgejo/actions/X`.
- **Q3. ✅ РЕШЕНО (C).** Деплой машин **не реализуется** в текущей миграции, но **контракт деплоя фиксируется сейчас** (см. раздел 6 «Контракт деплоя»). Перенос CI делается 1:1 (lift-and-shift). Выбор инструмента доставки (`deploy-rs` / `colmena` / `nixos-rebuild switch` по SSH / `nixos-anywhere`), SSH-auth к целевым машинам, стратегия rollback — отдельная следующая задача.
- **Q4. ✅ РЕШЕНО (B).** Path-based ядро + опциональные **provider-пресеты** (`sops` / `vault` / `systemd`).
  Модуль объявляет `services.nixtache.forgejo-runner.secrets.<name>: types.path`; потребитель
  подставляет путь любого бэкенда напрямую (вариант A) **или** включает пресет, который авто-wire'ит
  объявления и пути. `nixtache` **не хранит** секреты и `.sops.yaml`. Vault покрывается через
  `vault-agent` template (статичный файл) или `numtide/systemd-vaultd` (`$CREDENTIALS_DIRECTORY`).
- **Q5. ✅ РЕШЕНО (A).** Git-подпись и push бота унифицируются через единый ключ.
  (1) `ssh-setup` становится параметризованным: `inputs: git-host, git-user` (вместо хардкода
  `code.zinzaguras.ru`/`fbot`), кладёт ключ в `~/.ssh/id_key`, экспортирует путь наружу через output.
  (2) `update-flake.yml` использует **тот же путь** (`~/.ssh/id_key`, не `~/.ssh/id_rsa`) и тот же
  `core.sshCommand`, что и `ssh-setup` — чинит текущее несоответствие `id_rsa` vs `id_key`.
  (3) Источник ключа в модуле (`LoadCredential` путь) даётся provider-пресетом Q4, не хардкодится.

---

---

## 6. Контракт деплоя (контракт сейчас, реализация — отдельная задача)

> ⚠️ **SUPERSEDED — реализовано в `doc/specs/0001-direct-deploy.md` (Batch A–E).**
> Этот раздел — исходный набросок контракта времён миграции CI (Q3: «контракт
> сейчас, реализация — отдельная задача»). Финальный дизайн и имплементация
> ушли в `0001-direct-deploy.md` + `direct-deploy/`. **Инструмент доставки
> выбран: никакого deploy-rs/colmena/sudo** — активация через root-юнит
> `nixtache-apply.service` + polkit (V2); server self-update — через
> `systemd-sysupdate` A/B (`method = "ab-image"`). Ниже — оригинальный текст,
> оставлен для исторического контекста.

> Согласно решению Q3: контракт фиксируется сейчас, реализация переносится в следующую задачу.
> Цель раздела — зарезервировать место и интерфейс, чтобы миграция не закрыла путь к деплою,
> и чтобы будущий выбор инструмента уже имел «точку приземления» в `nixtache`.

### 6.1. Резервируемые артефакты (создаются как заглушки)

| Артефакт | Назначение | Статус |
|---|---|---|
| `nixtache/.forgejo/workflows/deploy.yml` | Reusable workflow с `on: workflow_call` + `workflow_dispatch`. Принимает `inputs.target` ∈ `{desktop, laptop, server}` и `inputs.mode` ∈ `{build, dry-activate, test, switch}`. Внутри: checkout вызывающего репо → сборка `.#nixosConfigurations.$target` → (placeholder) активация. | Заглушка: только сборка; активация — `echo "TODO: deploy"` с `exit 0`. |
| `nixtache/.forgejo/actions/deploy-target/` | Composite-action, куда позже уйдёт логика доставки (вызов `deploy-rs`/`colmena`/`nixos-rebuild`). | Заглушка (`action.yml` с `run: echo "deploy implementation pending"`). |
| `nixtache/.forgejo/workflows/deploy-trigger.yml` *(опц.)* | Тонкий вызывающий файл-пример для `nixos-configuration` (по аналогии с Q2). | Пример/документация; копируется в целевой репо при реализации. |

### 6.2. Интерфейс reusable-workflow `deploy.yml` (контракт)

```yaml
# nixtache/.forgejo/workflows/deploy.yml
name: Deploy NixOS target
on:
  workflow_call:
    inputs:
      target:
        type: string
        required: true
        description: "Целевая машина: desktop | laptop | server"
      mode:
        type: string
        default: "dry-activate"
        description: "build | dry-activate | test | switch"
  workflow_dispatch:
    inputs:
      target:
        type: choice
        options: [desktop, laptop, server]
      mode:
        type: choice
        default: dry-activate
        options: [build, dry-activate, test, switch]

jobs:
  deploy:
    runs-on: nixos
    timeout-minutes: 4320
    steps:
      - uses: actions/checkout@v4
        with: { lfs: true }
      - uses: ./.forgejo/actions/ssh-setup          # переиспользуем (см. Q5)
      - uses: ./.forgejo/actions/deploy-target        # заглушка → реализация позже
        with:
          target: ${{ inputs.target }}
          mode: ${{ inputs.mode }}
```

### 6.3. Что **обязательно** решить в задаче реализации деплоя (не сейчас)

1. **Инструмент:** `deploy-rs` vs `colmena` vs `nixos-rebuild switch` по SSH vs `nixos-anywhere` (для первичной установки).
2. **SSH-доступ раннера к целям:** выделенный deploy-key (см. Q4), авторизованный на `desktop/laptop/server`; через LAN/WireGuard/AmneziaWG.
3. **Безопасность:** `mode: switch` должен быть защищён (manual approval / environment protection / separate secret scope).
4. **Rollback:** стратегия отката (nix profile generations / `nixos-rebuild switch --rollback`).
5. **Влияние на сервисы:** простой `nextcloud`, `matrix`, `monero`, `forgejo` и т.д. — определить окна/стратегию.
6. **Секреты для активации:** если деплою нужны секреты целевых машин — механизм их доставки (не дублировать основной sops машин).

> Контракт намеренно **не фиксирует** инструмент, чтобы не блокировать миграцию; но гарантирует,
> что `nixtache` структурно готов принять деплой без перестройки архитектуры Q1/Q2.

---

## 7. Порядок выполнения

1. ~~Зафиксировать ответы на Q1–Q5.~~ ✅ (все решены)
2. Инициализировать `flake.nix` в `nixtache`, описать `nixosModules.forgejo-runner` (Q1=A).
3. Перенести и **параметризовать** модуль `forgejo-runner` (URL инстанса, домен/порт кэша, label, лимиты, knownHosts, nix-настройки).
4. Реализовать path-based контракт секретов + provider-пресеты `sops`/`vault`/`systemd` (Q4=B).
5. Перенести `.forgejo/actions/*`; параметризовать `ssh-setup` (`git-host`, `git-user`) (Q5=A).
6. Перенести workflows как reusable (`on: workflow_call`) + тонкие обёртки в `nixos-configuration` (Q2=B). **Спайк** cross-repo action-path на серверном Forgejo до реализации.
7. Унифицировать Git-подпись бота: единый путь ключа в `ssh-setup` и `update-flake.yml` (Q5=A).
8. Создать заглушки контракта деплоя (раздел 6, Q3=C).
9. Подключить `nixtache` как flake-input в `nixos-configuration`; удалить перенесённый `server/services/forgejo-runner.nix`; оставить `gitlab-runner` как есть.
10. Проверить сборку `nixos-configuration` и работоспособность раннера.

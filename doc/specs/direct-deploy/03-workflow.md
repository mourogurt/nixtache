# 03 — Workflow `deploy.yml`

> Этап 3 из `0001` §11. Кодовая детализация §7 `0001`.
> **Статус:** 📝 черновик имплементации.

## Что это

Reusable workflow `nixtache/.forgejo/workflows/deploy.yml` (`on: workflow_call` +
триггер на успех сборки; опц. `workflow_dispatch` **без inputs**). Тонкая обёртка
в consumer по аналогии с `nix-check.yml`. **Inputs убраны** — mode определяется
веткой.

## Триггеры + mode по ветке

| Событие | Ветка | mode |
|---|---|---|
| успех `nix-check` (после merge) | `main` | `switch` |
| успех `nix-check` (в PR) | ≠ `main` | `dry-activate` |
| `workflow_dispatch` (без inputs) | любая | по ветке запуска |

Деплой стартует **когда всё собралось** (`nix-check` строит все
`nixosConfigurations` + `devShells`). PR review/merge = гейт (§9.1).

### Два варианта проводки

> **S5 (решено):** фиксируем **вариант (b) Combined pipeline** как основной.

- **(b) Combined pipeline — ВЫБРАН.** Один workflow: job `build` (`uses:
  nixops/nixtache/.forgejo/workflows/nix-check.yml@main`, **без дублирования
  шагов**) → job `deploy` с `needs: build`. mode из `github.ref` напрямую, явный
  `needs`. Минус — деплой жёстко сцеплен с nix-check workflow (принимается).
- **(a) `workflow_run`** на успех `nix-check.yml` — альтернатива, если позже
  захочется развязать workflow'ы: `workflow_run` бежит в контексте default-branch,
  branch PR-а берётся из `github.event.workflow_run.head_branch`. Минус: лишний
  round-trip, спец. обработка PR-ветки.

> Важно: `nix-check.yml` уже **reusable** (`on: workflow_call`), поэтому `build`
> обязан вызывать его через `uses:`, а **не** копировать шаги inline — иначе
> нарушается принцип «nixtache — единственный источник CI-логики» (AGENTS.md).

## Скелет `deploy.yml` (вариант b — combined)

```yaml
name: ci          # объединённый: build → deploy
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build:          # = nix-check (reusable call, без дублирования шагов)
    uses: nixops/nixtache/.forgejo/workflows/nix-check.yml@main
    secrets: inherit

  deploy:
    needs: build
    runs-on: nixos             # label существующего default-инстанса (§7.4 0001)
    steps:
      - uses: actions/checkout@v4              # caller repo (nixosConfigurations)
      - uses: actions/checkout@v4              # nixtache — для composite-actions
        with: { repository: nixops/nixtache, path: .nixtache, ref: main }
      - name: mode from branch
        run: echo "MODE=$([ '${{ github.ref }}' = refs/heads/main ] && echo switch || echo dry-activate)" >> $GITHUB_ENV
      - uses: ./.nixtache/.forgejo/actions/deploy-target
```

> Forgejo UI: reusable call (вариант a) рендерится как 2 джобы (`deploy` 0s caller
> + `deploy-1` работа) — expected (см. `nixtache/AGENTS.md` «Reusable workflow
> mechanics»).

## Тонкая обёртка consumer'а

`.forgejo/workflows/deploy.yml` в consumer (если вариант a — отдельный workflow):
```yaml
jobs:
  deploy:
    uses: nixops/nixtache/.forgejo/workflows/deploy.yml@main
    secrets: inherit
```
В варианте (b) consumer просто не имеет своего deploy-файла — nix-check workflow
(тоже тонкая обёртка) расширяется job'ом `deploy` через `needs`.

## Сходимость с `autoUpgrade`

`system.autoUpgrade` тянет только `main`. На PR (≠ main) — CI даёт
`dry-activate` (предпросмотр), `autoUpgrade` игнорит → нигде не мутирует. На
`main` — CI `switch` (быстро) + `autoUpgrade` перестраховочно по таймеру. (§7.1.)

## Артефакты этапа

- `.forgejo/workflows/deploy.yml` (nixtache) — reusable (вариант a) ИЛИ job в
  `nix-check.yml` (вариант b).
- consumer: thin wrapper (a) / расширение nix-check wrapper'а (b).
- зависимости: `nix-check.yml` (триггер/`needs`), `deploy-target` action (02).

## Зависимости / следующие этапы

- ← `02-action.md` (вызывает action).
- → `04-consumer-wiring.md` (consumer: карта целей + приёмный модуль + ключи).

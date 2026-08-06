# direct-deploy — поэтапная детализация

`../0001-direct-deploy.md` — **финальный дизайн/решения** (Q1–Q9, N1–N6
закрыты). Эта директория — **поэтапная детализация под имплементацию**: каждый
файл раскрывает один этап (из §11 `0001`) до кодового уровня — точные Nix-опции,
action-шаги, тест-сценарии.

## Роль модели (vendor-agnostic)

nixtache не фиксирует роли машин. **Infra-машина** — та, что крутит runner
(`services.nixtache.runner`); **таргет-машины** — те, куда деплоит фича. В
reference workspace (`codemaster/nixos-configuration`) infra = `server`,
таргеты = `desktop`/`laptop`/`server`. Ниже `server`/`desktop`/`laptop` —
**примеры**, не роли.

## Модель доставки (два пути)

1. **`system.autoUpgrade`** — автономный дефолт (по таймеру тянет `main`).
2. **CI `deploy`** — ускоритель: автофайрится на зелёном `nix-check`, mode по
   ветке — PR (≠ `main`) → `dry-activate`, `main` → `switch`. PR review = гейт.

См. `0001` §1 «Модель доставки».

## Файлы по этапам (§11 из 0001)

| Файл | Этап | Статус |
|---|---|---|
| [`01-map-contract.md`](01-map-contract.md) | 1. Контракт: `deployTargetType` + `deploy.targets` + `deploy.nix` | 📝 |
| [`02-action.md`](02-action.md) | 2. Action `deploy-target` (discovery → probe → activate) | 📝 |
| [`03-workflow.md`](03-workflow.md) | 3. Workflow `deploy.yml` (mode по ветке, без inputs) | 📝 |
| [`04-consumer-wiring.md`](04-consumer-wiring.md) | 4. Consumer: deploy-keys + приёмный модуль (apply-юнит + polkit) | 📝 |
| [`05-rollback.md`](05-rollback.md) | 7. Auto-rollback Tier 0/1 (probe+rollback внутри `nixtache-apply.service`) | 📝 |
| [`06-ab-image.md`](06-ab-image.md) | 8. Server A/B image (systemd-sysupdate, chicken-and-egg) | 📝 |
| [`07-cross-arch.md`](07-cross-arch.md) | 9. Cross-arch (binfmt на runner-host) | 📝 |

Tier-1 (probe `criticalUnits` + rollback) — внутри root-юнита
`nixtache-apply.service` (см. [`05-rollback.md`](05-rollback.md) Tier-1),
триггерится action'ом ([`02-action.md`](02-action.md) `_liveApply`).

**Legend:** 📝 в работе · ⏳ запланирован · ✅ готов

## Сквозные контракты (действуют во всех этапах)

- **Vendor-agnostic:** nixtache не хардкодит хосты/домены/ключи; всё через
  опции потребителя.
- **Path-based секреты:** deploy-ключи — `types.path`, поставляются потребителем
  (sops/agenix/vault/systemd), монтируются через `LoadCredential` (как
  `flake_ssh_*`/`update_ssh_*`).
- **Опциональность (R1):** нет записи в карте / нет кредов → цель не деплоится
  (skip, не fail CI).
- **Недоступный хост (R5):** короткий SSH-probe → skip+warn, не роняет CI.

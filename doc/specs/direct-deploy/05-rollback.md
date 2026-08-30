# 05 — Auto-rollback (Tier 0 / Tier 1) — V2

> Этап 7 из `0001` §11. Детализация §8.5/§9.3 `0001`.
> **Статус:** 📝 черновик.

## Обзор

Два уровня авто-отката + ручной fallback. Общий вход — **`criticalUnits`** (в
конфиге таргета, приёмный модуль `deploy-target`, `04` §B):

| Уровень | Что ловит | Где | Механизм |
|---|---|---|---|
| **Tier 0** | после boot критичный юнит не поднялся | таргет (приёмный модуль) | `nixtache-health-check.service` (`Before=`+`RequiredBy=` `boot-complete.target`) → нет bless → (bootCounting) откат generation на след. загрузке |
| **Tier 1** | живой `switch` сломал сервисы | таргет (root-юнит `nixtache-apply.service`) | set+switch → probe `criticalUnits` локально → при fail `nix-env --set <prev>` (auto-revert) + `exit 1` → джоба краснеет |
| *(manual)* | точечный откат / когда авто не сработало | человек | см. «Ручной fallback» ниже |

> **V2:** Tier-1 раньше планировался через deploy-rs (`--checks`/`activate.custom`),
> но флага `--checks` не существует, nodeless ad-hoc вызов deploy-rs невозможен.
> Поэтому probe перенесён **внутрь root-юнита** на самой цели — чище, не зависит от
> deploy-rs, и устойчив к падению sshd (probe крутится локально как root, SSH не
> нужен). deploy-rs выкинут целиком.

## `criticalUnits` — единый вход обоих tier'ов

Список systemd-юнитов, которые **должны** быть активны после boot/switch (состав
выбирает consumer — nixtache дефолт `[]`, нейтрален; в reference workspace
добавляют `wireguard-awg0.service` (AmneziaWG-mesh) как universal + per-target
forgejo/контейнер на runner-host, и т.п.). Живёт в конфиге **таргета**
(`services.nixtache.deploy-target.criticalUnits`) → оба tier'а читают его
напрямую из приёмного модуля (никакого `nix eval` дублирования, никакого второго
источника). HTTP-probes отложены (N2).

## Tier 0 — boot-time health-check (приёмный модуль)

`nixtache-health-check.service` (oneshot, генерируется из `criticalUnits`):

```nix
systemd.services.nixtache-health-check = {
  description = "Gate boot-complete.target on nixtache criticalUnits being active";
  serviceConfig.Type = "oneshot";
  path = [ pkgs.systemd ];
  # Strong gating: boot-complete.target Requires + runs After this service.
  # If this fails, boot-complete never reaches "active" → no bless.
  before     = [ "boot-complete.target" ];
  requiredBy = [ "boot-complete.target" ];
  script = let
    probes = lib.concatStringsSep " && "
      (map (u: "systemctl is-active --quiet --wait ${lib.escapeShellArg u}") cfg.criticalUnits);
    timeout = toString cfg.healthCheckTimeout;
  in ''
    deadline=$(( $(date +%s) + ${timeout} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if ${probes}; then exit 0; fi
      sleep 5
    done
    echo "nixtache-health-check: criticalUnits not all active within ${timeout}s — boot not blessed" >&2
    exit 1
  '';
};
```

**Поведение:** oneshot крутит `systemctl is-active --wait <unit>` для каждого
`criticalUnits` в окне `healthCheckTimeout` (default 300с — машины грузятся долго, N3).
Все активны → `exit 0` → `boot-complete.target` достигнут → `systemd-bless-boot`
метит generation «good». Иначе `exit 1` → target не достигнут (RequiredBy) → нет bless.

**Откат generation** требует **bootCounting** (N1, consumer-scope): generation с
boot-счётчиком; обнуливший счётчик → грузится прошлая. Без bootCounting Tier-0 только
«не благословляет» (без автоматического отката) — тогда спасает Tier-1 (для `live`) или
ручной fallback. Для `ab-image` bootCounting — часть prep (06 §5).

## Tier 1 — live probe+rollback внутри `nixtache-apply.service`

> **B1 (V2):** probe живёт **внутри root-юнита** `nixtache-apply.service` на самой
> цели, не в action и не флагом deploy-rs. Причина — надёжность: если апдейт ломает
> `sshd`, SSH-based rollback бесполезен (деплоер не достучится), проверка обязана
> работать локально на цели уже после мутации.

### Механика: root-юнит `nixtache-apply.service`

Юнит (провижинится приёмным модулем, см. `modules/deploy-target/apply.nix`) делает
активацию + probe + rollback одной атомарной операцией:

1. читает `/var/lib/nixtache/pending-system` → closure path `P`;
2. захватывает `prev=$(readlink -f /nix/var/nix/profiles/system)` (pre-apply);
3. `nix-env -p /nix/var/nix/profiles/system --set "$P"` + `"$P/bin/switch-to-configuration" switch`;
4. **probe**: в окне `healthCheckTimeout` локально опрашивает
   `systemctl is-active --quiet --wait <unit>` для каждого `criticalUnits`;
5. при fail → `rollback()`: `nix-env --set "$prev"` + повторный switch + `exit 1`;
6. при success → удаляет pointer + `exit 0`; при провале — тоже удаляет
   (анти-retry, см. 04 §B) и `exit 1`.

Юнит запускается deploy-юзером через `systemctl start nixtache-apply.service`
(polkit-авторизация, см. `02-action.md` `_liveApply`). `systemctl start` для
Type=oneshot **синхронный** — блокирует до завершения юнита, exit-код = результат
юнита → действие (action) видит успех/провал по SSH exit-коду.

> Probe крутится на цели как **root** через dbus/systemctl → устойчив, даже если
> новый конфиг сломал sshd (deploy-юзеру SSH уже не нужен, юнит уже запущен).
> `criticalUnits` пуст → probe-фаза skip, юнит только activate (немедленный `exit 0`).

### Связь с картой — нет дублирования (V2)

> **B2 (V2):** `deploy.nodes` / `nixtache.lib.mkDeployNodes` / `activate.custom` —
> **убраны**. Карта (`services.nixtache.runner.deploy.targets`) даёт host/sshUser/
> sshPort/method; действие (action) `02` читает её из env `NIXTACHE_DEPLOY_TARGETS`
> и делает `nix copy` + `ssh systemctl start`. `criticalUnits`/`healthCheckTimeout`
> живут в приёмном модуле на цели (юнит их читает напрямую). Ни `deploy.nodes`, ни
> `nix eval`-дублирования — карта = единственный источник host/creds, приёмный
> модуль = единственный источник criticalUnits.

## Ручной fallback

Когда авто-откат не сработал (или нужен точечный откат конкретной generation):
deploy-юзер не имеет sudo (V2), поэтому откат делает **root на самой цели** (через
консоль/physical access / отдельный emergency-путь):

```bash
# на самой цели как root (deploy-юзер не может — нет sudo/doas/run0 по дизайну):
nixos-rebuild switch --rollback
# либо:
nix-env -p /nix/var/nix/profiles/system --switch-generation <N>
```

> Если нужен CI-triggered ручной откат без физического доступа, его можно дать
> отдельным polkit-правилом на `systemctl start nixtache-rollback.service`
> (root-юнит, делающий `nixos-rebuild --rollback`) — опционально, вне базового
> контракта.

## Asserts / тесты (`tests/deploy-target.nix`)

- `criticalUnits` непустой → `nixtache-health-check.service` wired
  (`before` + `requiredBy` содержат `boot-complete.target`).
- `healthCheckTimeout` default 300.
- `nixtache-apply.service` присутствует (Type=oneshot), его `script` содержит
  criticalUnits + rollback-ветку.
- `bootCounting` (consumer) связан с Tier-0 (warn если `criticalUnits` задан, а
  bootCounting off — Tier-0 не откатит без него).
- `autoProvision=false` без user → eval отказывает (assertion).

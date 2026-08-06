# 02 — Action `deploy-target` (V2)

> Этап 2 из `0001` §11. Кодовая детализация §7.2 `0001`.
> **Статус:** 📝 черновик имплементации.

## Что это

Composite-action `.forgejo/actions/deploy-target/action.yml` (nixtache). Для
каждого `nixosConfigurations.<name>` из флэйка: **discovery → probe → activate**,
с веткой по `method` (`live` | `ab-image`). Все skip-ветки = `continue` (не
роняют CI); `exit 1` — только на hard-error сборки/активации.

> **V2:** активация **без deploy-rs и без sudo/doas/run0**. Копирование closure —
> `nix copy --to`, активация — root-юнит `nixtache-apply.service` на цели, который
> deploy-юзер триггерит через polkit (`systemctl start`). Tier-1 probe+rollback
> вшиты **внутрь юнита** (см. `05-rollback.md`), action только передаёт closure
> и читает exit-код.

## Контекст джобы (откуда берёт данные)

| Источник | Что |
|---|---|
| `$NIXTACHE_DEPLOY_TARGETS` | JSON-карта целей (env, из `01-map-contract.md`) |
| `$CREDENTIALS_DIRECTORY/deploy_ssh_<name>` | приватные ключи (LoadCredential) |
| `FORGEJO_REF` / ветка | mode: `main` → `switch`, иначе `dry-activate` (§7.1) |
| `$HAS_SANDBOX_CAP` | `1` → собирать с sandbox; `0`/unset → добавлять `--no-sandbox` к `nix build`/`nixos-rebuild` (как `rebuild-configurations`) |
| `/var/lib/nixtache/ab-stage/` | central staging-dir (bind-mount в контейнер) для ab-image |
| `$NIXTACHE_RUNNER_HOST` | адрес runner-host'а (env от runner-модуля) — для self/remote-определения в ab-image |

> deploy-rs / `deploy.nodes` / `mkDeployNodes` — **убраны в V2**. action не
> вызывает `deploy`; копирование и активацию делают nixos-примитивы + systemd.

## Алгоритм (скелет)

```bash
mode=$([ "${FORGEJO_REF##*/}" = main ] && echo switch || echo dry-activate)
configs=$(nix flake show --json | jq -r '.nixosConfigurations | keys[]')
map=$NIXTACHE_DEPLOY_TARGETS

for cfg in $configs; do
  t=$(echo "$map" | jq -e --arg n "$cfg" '.[$n]') || { log "skip: нет в карте";  continue; }
  [ "$(jq -r .hasKey <<<"$t")" = "true" ] || { log "skip: нет deploy-ключа";     continue; }
  [ "$(jq -r .enable <<<"$t")"  = "true" ] || { log "skip: enable=false";        continue; }

  # --- probe (R5): короткий SSH-pинг тем же ключом ---
  key=$CREDENTIALS_DIRECTORY/deploy_ssh_${cfg}
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$key" \
          -p "$(jq -r .sshPort <<<"$t")" "$(jq -r .sshUser <<<"$t")@$(jq -r .host <<<"$t")" true; then
     warn "хост недоступен — пропускаю"; continue
  fi

  # --- activate (mode + method) ---
  mkdir -p artifacts
  case "$(jq -r .method <<<"$t")" in
    live)     _liveApply "$cfg" "$t" "$mode" "$key" &> artifacts/deploy_${cfg}.log ;;
    ab-image) _abImage   "$cfg" "$t" "$mode"        &> artifacts/deploy_${cfg}.log ;;
  esac || { echo "deploy FAILED for $cfg"; tail -n 50 artifacts/deploy_${cfg}.log; exit 1; }
done
```

## Ветка `method = "live"` (default)

```bash
_liveApply(cfg, t, mode, key) {
  user=$(jq -r .sshUser <<<"$t"); host=$(jq -r .host <<<"$t"); port=$(jq -r .sshPort <<<"$t")
  noSandbox=$([ "${HAS_SANDBOX_CAP:-0}" = "1" ] || echo "--no-sandbox")   # M3: sandbox cap
  extra=$(jq -r '.extraOptions[]?' <<<"$t")

  # 1. build toplevel на раннере (sandbox; --no-sandbox если cap off)
  P=$(nix build --no-link --print-out-paths $noSandbox .#nixosConfigurations.$cfg.config.system.build.toplevel)

  if [ "$mode" = dry-activate ]; then                       # PR-предпросмотр — без мутации
     nixos-rebuild dry-activate --flake .#$cfg \
        --target-host $user@$host --use-remote-sudo $noSandbox $extra
     return
  fi

  # 2. copy closure на цель (deploy-юзер; allowed-users NixOS default)
  nix copy --to ssh://$user@$host$([ -n "$port" ] && [ "$port" != 22 ] && echo "?port=$port") "$P" $extra

  # 3. drop pointer + trigger root apply-unit (polkit; синхронно — oneshot блокирует до финиша)
  ssh -i "$key" -p "$port" "$user@$host" "echo '$P' > /var/lib/nixtache/pending-system \
                                       && systemctl start nixtache-apply.service"
  # exit code SSH = exit code apply-unit:
  #   set profile → switch → probe criticalUnits → rollback on fail (Tier-1, вшит в юнит, §8.5)
  #   fail → exit !=0 → джоба краснеет
}
```

> **Почему не `--target-host --use-remote-sudo` для switch:** он требует sudo на
> deploy-юзере. V2 убирает escalation-тулы целиком — root-работу делает юнит,
> авторизация через polkit. `dry-activate` (без мутации) остаётся на
> `nixos-rebuild` — ему `--use-remote-sudo` допустим для diff-only.

## Ветка `method = "ab-image"`

```bash
_abImage(cfg, t, mode) {
  # 1. build image (UKI + <id>_<v>.nix-store.raw + SHA256SUMS)
  img=$(nix build --print-out-paths .#nixosConfigurations.$cfg.config.system.build.sysupdate-package)
  # 2. central stage — per-cfg dir, versioned files (bind-mount /var/lib/nixtache/ab-stage/)
  stage=/var/lib/nixtache/ab-stage/${cfg}
  mkdir -p "$stage" && cp -t "$stage"/ "$img"/*              # versioned files (<id>_<ver>.raw), нет перезаписи
  [ "$mode" = dry-activate ] && return                       # PR: только build+stage
  # 3. apply — по топологии таргета (local-self vs remote)
  if [ "$(jq -r .host <<<"$t")" = "$NIXTACHE_RUNNER_HOST" ]; then   # local-self
     ssh -i "$key" -p "$port" "$user@$host" \
        "touch /var/lib/nixtache/ab-pending && systemctl start nixtache-ab-apply.service"
     # gating сам: idle-wait → sysupdate (file://) → reboot → снять pending
  else                                                               # remote
     ssh -i "$key" -p "$port" "$user@$host" \
        "systemctl start systemd-sysupdate.service" || true
     # цель тянет HTTPS с nginx runner-host'а (таймер тоже сработал бы сам)
  fi
  # action НЕ ждёт ребута — асинхронно (06-ab-image.md)
}
```

**Central staging всегда на runner-host** (`/var/lib/nixtache/ab-stage/<cfg>/`,
versioned files; контейнер пишет через bind-mount, nginx раздаёт по HTTPS). Apply по
топологии (action сравнивает `t.host` с `$NIXTACHE_RUNNER_HOST` — env от runner-модуля):
- **local-self** (цель = runner-host): signal `nixtache-ab-apply` → gating ждёт idle
  раннеров → sysupdate читает `file://` → слот B → reboot.
- **remote** (цель ≠ runner-host): SSH-trigger `systemd-sysupdate` цели → она тянет
  образ по HTTPS с nginx runner-host'а → слот B → reboot (или свой sysupdate-таймер).

> mode для ab-image: `dry-activate` = build+central-stage (предпросмотр, без apply);
> `switch` = build+stage+apply. Конкурентность — versioned-файлы + sysupdate берёт
> старшую версию (см. 06 «Конкурентность»). Триггеры ab-image (`touch ab-pending`,
> `systemctl start systemd-sysupdate`) deploy-юзер делает через **polkit** (как и для
> live-юнита) — отдельные polkit-правила, без sudo.

## Tier-1 health-probe (внутри `nixtache-apply.service`)

> **B1 (V2):** флага `deploy-rs --checks` не существует — probe реализован **внутри
> root-юнита** на самой цели, не флагом deploy-rs.

`criticalUnits` цели (приёмный модуль `nixtache.nixosModules.deploy-target`,
единый источник с Tier-0) вшиты в скрипт `nixtache-apply.service`: после
`nix-env --set <closure>` + `switch-to-configuration switch` юнит локально
опрашивает `systemctl is-active --wait <unit>` в окне `healthCheckTimeout`; при
fail — `nix-env --set <prev>` (откат к pre-apply closure) + повторный switch +
`exit 1` → `systemctl start` возвращает ненулевой код по SSH → джоба краснеет. Это
Tier-1 (§8.5). Probe крутится на цели как root (dbus/systemctl) → устойчив, даже
если новый конфиг сломал sshd. Сам action probe не выполняет — только передаёт
closure и читает exit-код. Для `ab-image` Tier-1 не нужен — rollback =
boot-counting (Tier-0).

## Логи / артефакты

- `artifacts/deploy_<cfg>.log` — полный вывод сборки+активации на цель (как
  `rebuild_<config>.log`); upload через `actions/upload-artifact`.
- skip-ветки → запись в лог + `continue`.
- оффлайн-цель (probe fail) → skip+warn (R5), CI не роняет.

## Артефакты этапа

- `.forgejo/actions/deploy-target/action.yml` — composite (алгоритм выше).
- зависимости: `$NIXTACHE_DEPLOY_TARGETS` (01), LoadCredential-ключи,
  staging-dir bind-mount для ab-image (nixtache runner module). **deploy-rs не нужен.**

## Зависимости / следующие этапы

- ← `01-map-contract.md` (карта + ключи в env).
- ← `modules/deploy-target/apply.nix` (Batch B) — `nixtache-apply.service` на
  цели, который `_liveApply` триггерит.
- → `03-workflow.md` (`deploy.yml`: mode по ветке, без inputs, вызывает action).
- → `05-rollback.md` (Tier-0/1 детально; Tier-1 probe внутри apply-юнита),
  `06-ab-image.md` (ab-image ветка + gating).

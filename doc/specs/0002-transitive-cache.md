# Спека 0002 — Транзитивный (pull-through) кэш в nixtache

> **Статус:** черновик (на ревью) — **до реализации жду подтверждения**
> (см. «Контрольная точка» в §11)
> **Дата:** 2026-08-06
> **Зона:** `nixtache` (`modules/runner/cache.nix` + новый `modules/runner/mirror.nix`
> + host-side nginx vhost) + consumer-side проводка доверия (`trusted-public-keys`).
> **Ссылки:** `modules/runner/cache.nix` (текущий `nix-serve-ng` + nginx vhost);
> `doc/migration-plan.md` §«Бинарный кэш» (`bincache.zinzaguras.ru`).

---

## 1. Цель

Сегодня кэш nixtache (`nix-serve-ng` внутри контейнера, vhost
`bincache.<domain>` на хосте) — **пассивный**: он отдаёт только то, что уже
лежит в локальном nix-сторе раннера (т.е. пути, собранные/загруженные самим
раннером). На запрос отсутствующего пути клиент получает `404` и идёт дальше
по своему списку `substituters` (обычно в `cache.nixos.org`).

**Цель этой спеки** — сделать кэш **транзитивным** (pull-through / lazy mirror):
при обращении потребителя к `bincache.<domain>` за путём, которого у nixtache
ещё нет, кэш сам идёт в upstream, скачивает путь и **хранит его у себя**, так
что:

1. первый запрос медленный (тянет из upstream), но **сохраняется локально**;
2. все последующие запросы того же пути обслуживаются из локального кэша
   (быстро, без ходки в upstream);
3. потребитель (desktop / laptop / другой CI) может держать **одну точку
   входа** (`bincache.<domain>`) и не дублировать конфигурацию upstream'ов на
   каждой машине — nixtache выступает единым кэшем-агрегатором для всего флота.

### Не-цели (out of scope)

- Полноценный **multi-tenant** кэш с пер-проектными неймспейсами (как Attic) —
  nixtache остаётся одним общим кэшем; проектная изоляция не требуется.
- **Prefetch / active warming** (предзагрузка популярных closure'ов по
  расписанию) — обозначим как опцию будущего; v1 = чисто lazy.
- Смена `nix-serve-ng` на Attic/Harmonia как часть этой спеки — обозначена как
  альтернатива (§7.3), но не вносится в модуль без отдельного решения.

---

## 2. Требования и ограничения

| # | Требование | Как обеспечено |
|---|---|---|
| R1 | **Vendor-agnostic** — nixtache не хардкодит upstream-URL'ы | Список upstream'ов — опция модуля (`mirror.upstreams`); default = `cache.nixos.org` |
| R2 | **nixtache не хранит секреты** | Подпись остаётся на существующем `secrets.cachePrivateKey` (`types.path`); mirror не требует новых секретов |
| R3 | **Опциональность** — транзитивность можно выключить одной опцией | `mirror.enable = false` (default) → поведение идентично сегодняшнему (чистый `nix-serve-ng`) |
| R4 | **Локальные пути в приоритете** — путь, собранный раннером, отдаётся локальной подписью, не уходит в mirror | Маршрутизация nginx: local-first → 404 → mirror-fallback (§6) |
| R5 | **Persistance** — скачанное из upstream переживает рестарт | Кэш-директория на диске хоста (`mirror.cacheDir`), переживает `nixos-rebuild switch` |
| R6 | **Ограничение диска** — кэш не разрастается бесконечно | `proxy_cache_path ... max_size=… inactive=…` → eviction nginx cache-manager'ом |
| R7 | **Дедупликация конкурентных запросов** — N клиентов одновременно просят один новый путь → одна ходка в upstream | `proxy_cache_lock on;` (nginx коалесцирует) |
| R8 | **SSRF / open-upstream** — нельзя произвольно подсунуть upstream-URL через запрос | Upstream-список — фиксированная опция модуля; запросы идут только на заданные хосты |
| R9 | **Деградация безопасна** — upstream недоступен → 404/502 клиенту, но локальные пути продолжают отдаваться | local-first маршрут не зависит от доступности upstream |
| R10 | **Тестовое покрытие** (правило репо: «каждая опция — с тестом») | `tests/runner.nix` + сценарии mirror on/off, local-first, env-экспорт (§10) |

---

## 3. Контекст (что уже есть)

- **`modules/runner/cache.nix`** объявляет `cache.{enable,domain,port,package}`
  и `secrets.cachePrivateKey`; внутри контейнера крутится `services.nix-serve`
  (`nix-serve-ng`, подпись локальным ключом), на хосте — nginx-vhost
  `services.nginx.virtualHosts.${cfg.cache.domain}` с
  `locations."/".proxyPass = "http://localhost:${port}"`.
- **`store.nix`** при `store.path != "/"` relocate'ит стор в `<path>/nix` и
  инжектит `BindPaths` в `nix-serve` + `gitea-runner-*`. Кэш живёт поверх того
  же стора, что и сборки.
- В `default.nix` `nixSettings.substituters` уже содержит `cache.nixos.org` +
  зеркала SJTU/USTC/cernet — это **upstream-кандидаты** для mirror'а (тот же
  набор, что потребитель и так использует).
- Потребитель (`nixos-configuration/server/services/forgejo-runner.nix`)
  прокидывает `secrets.cachePrivateKey` и домен; `nixSettings` контейнера и
  конфиги desktop/laptop ссылаются на `bincache.zinzaguras.ru`.

**Что не так сейчас:** каждый потребитель (desktop, laptop, раннер) при промахе
в `bincache` идёт в upstream **самостоятельно** — т.е. одно и то же closure
качается многократно с разных машин, а `bincache` не аккумулирует «чужие»
пути. Транзитивный кэш делает `bincache` **суперсетом** upstream'ов.

---

## 4. Модель данных и дизайн

Ключевое решение — **двухуровневая (tiered) модель**, с явным выбором tier'а
опцией модуля. Это позволяет сделать простой/надёжный v1 сейчас и
дорастить до single-key trust позже.

### 4.1. Два tier'а

| Tier | Механика | Подпись narinfo | Где хранится скачанное | Сложность |
|---|---|---|---|---|
| **Tier 1 — nginx pull-through mirror** (default v1) | nginx `proxy_cache` перед upstream'ами; local-first (nix-serve-ng), на 404 → fallback в зеркало | **исходная** upstream'а (проксируется как есть) | nginx-кэш на диске хоста (`/var/cache/nixtache/mirror`) | низкая (чистый nginx, 0 своего кода) |
| **Tier 2 — store-integrated re-sign** (roadmap) | на 404 локального стора → `nix copy --from <upstream> <path>` импортирует путь в локальный стор, nix-serve-ng отдаёт его | **пере-подписанная** ключом nixtache | локальный nix-store (едино с собранными путями) | средняя/высокая (sidecar-демон + конкурентность) |

> **Почему два tier'а.** Tier 1 — это буквально то, как работают публичные
> nix-зеркала (TUNA/USTC/SJTU, которые уже в `nixSettings`) — отлаженный,
> без runtime-кода, с встроенной дедупликацией (`proxy_cache_lock`) и
> eviction (`max_size`/`inactive`). Его минус — потребитель должен доверять
> **и** ключу nixtache (для локальных путей), **и** upstream-ключам (для
> зеркалируемых narinfo, т.к. подпись не пере-подписывается).
> Tier 2 даёт **single-key trust** (доверяем только nixtache) и единство с
> стором/gc раннера, ценой runtime-демона с блокировками. Его и имеет смысл
> делать, когда захочется «один ключ на весь флот».

### 4.2. Что НЕ меняется

- `nix-serve-ng`, ключ подписи, `cache.{domain,port,package}` — на месте.
- Маршрутизация остаётся **local-first**: локально собранные пути всегда
  отдаются локальной подписью nixtache, никогда не уходят в mirror.

---

## 5. Контракт данных: `cache.mirror.*`

Новые опции (подмодуль в `modules/runner/types.nix` → `mirrorUpstreamType`;
опции в `modules/runner/mirror.nix`, merge в тот же nginx-vhost, что и
`cache.nix`):

### 5.1. `cache.mirror` (блок)

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `enable` | `bool` | `false` | Включить pull-through (R3). `false` → поведение идентично сегодняшнему |
| `upstreams` | `listOf mirrorUpstreamType` | `[ cache.nixos.org ]` | Упорядоченный список upstream'ов (R1, R8); запрос идёт по порядку до первого 200 |
| `cacheDir` | `path` | `/var/cache/nixtache/mirror` | Каталог nginx `proxy_cache_path` на хосте (R5) |
| `maxSize` | `str` | `100g` | Лимит размера кэша (R6); nginx cache-manager вытесняет старое |
| `inactive` | `str` | `30d` | Eviction по давности последнего доступа (R6) |
| `resign` | `bool` | `false` | **Tier-2 toggle** (roadmap): `true` → импорт в стор + пере-подпись вместо HTTP-mirror. В v1 при `true` — assertion-fail с указанием на §7.3 (не реализовано) |
| `cacheLockTimeout` | `str` | `60s` | `proxy_cache_lock_timeout` — сколько ждать конкурентный запрос, пока первый тянет из upstream (R7) |
| `upstreamTimeout` | `str` | `30s` | `proxy_connect/read/send_timeout` до upstream |

### 5.2. `mirrorUpstreamType` (один upstream)

| Поле | Тип | Default | Назначение |
|---|---|---|---|
| `url` | `str` (non-empty) | **обязательный** | Базовый URL substituter'а (`https://cache.nixos.org/`, `https://mirror.sjtu.edu.cn/nix-channels/store`, …) |
| `publicKey` | `str` | **обязательный** | Соответствующий `trusted-public-keys` ключ (`cache.nixos.org-1:6NCHd…`). Нужен consumer'у для проверки зеркалируемых narinfo (Tier 1) |

> `publicKey` здесь — **не секрет**, а публичный ключ upstream'а. Он нужен
> модулю, чтобы (а) документировать consumer'у, какие ключи добавить в
> `trusted-public-keys`, и (б) опционально сгенерировать готовый блок
> `substituters`/`trusted-public-keys` для consumer-машин. Секретов в блоке
> нет — контракт R2 не нарушается.

---

## 6. Маршрутизация запросов (Tier 1, nginx)

nginx-vhost на хосте (тот же, что в `cache.nix`, расширяется в `mirror.nix`):

```
         клиент (desktop/laptop/runner)
                    │  GET /<hash>.narinfo
                    ▼
   ┌─────────────────────────────────────────────┐
   │  nginx vhost  bincache.<domain>             │
   │                                             │
   │  /nix-cache-info  ───────────────────►  LOCAL (nix-serve-ng)   [всегда локально]
   │                                             │
   │  *.narinfo  /  *.nar(.xz|.zst)?             │
   │     ┌─ try LOCAL (nix-serve-ng)             │
   │     │   200  ──► отдать (локальная подпись) │   ← R4: local-first
   │     │   404  ──► @mirror                     │
   │     │                                        │
   │     └─ @mirror: proxy_cache + upstream-цепочка
   │              proxy_cache_lock on            │   ← R7: дедуп
   │              upstreams[0] (cache.nixos.org) │   ← R1/R8: фиксированный список
   │                404 → upstreams[1] (SJTU) …  │
   │              200 → закэшировать в cacheDir  │   ← R5/R6
   │              всё 404/5xx → 404 клиенту       │   ← R9
   └─────────────────────────────────────────────┘
```

Ключевые директивы nginx (скелет, точный синтаксис — на имплементации):

```nginx
# один раз в http{} (генерируется модулем на хосте):
proxy_cache_path /var/cache/nixtache/mirror levels=1:2
                 keys_zone=nixtache_mirror:100m
                 max_size=100g inactive=30d use_temp_path=off;

# внутри server{} vhost'а:
location = /nix-cache-info { proxy_pass http://localhost:PORT; }   # всегда LOCAL

location ~ \.narinfo$ {
  recursive_error_pages on;
  proxy_intercept_errors on;
  error_page 404 = @mirror;
  proxy_pass http://localhost:PORT;                                 # LOCAL first
}
location ~ \.nar(\.xz|\.zst)?$ {
  recursive_error_pages on;
  proxy_intercept_errors on;
  error_page 404 = @mirror;
  proxy_pass http://localhost:PORT;                                 # LOCAL first
}

location @mirror {
  proxy_cache nixtache_mirror;
  proxy_cache_lock on;                  # R7: 1 fetch на ключ
  proxy_cache_lock_timeout 60s;
  proxy_cache_valid 200 30d;            # кэшируем только успешные
  proxy_cache_key $uri;
  # цепочка upstream'ов: по порядку до первого 200
  proxy_next_upstream error timeout http_404;
  proxy_pass https://cache.nixos.org/;   # + доп. location'ы/backup для 2-го/3-го
}
```

### Почему narinfo и nar всегда приходят из **одного** источника

narinfo содержит поле `URL:` (путь к nar) и `Sig:` (подпись). Клиент запрашивает
nar по пути из narinfo **на том же хосте**. Поскольку и narinfo, и nar для
одного пути кэшируются одним и тем же `proxy_cache` (ключ = `$uri`), источник
для них согласован: оба либо локальные (nix-serve-ng, подпись nixtache), либо
оба зеркальные (из upstream, подпись upstream). Рассинхрона не возникает.

### `/nix-cache-info` — всегда локально

Этот эндпоинт описывает **наш** кэш (`StoreDir`, `WantMassQuery` и т.д.); зеркало
его не отдаёт (чтобы не подсунуть upstream'овский). Поэтому `location =` →
только LOCAL.

---

## 7. Tier 2 — store-integrated re-sign (roadmap)

Включается опцией `mirror.resign = true`. Реализуется **sidecar-сервисом**
внутри контейнера (где живёт nix-store + ключ подписи), который слушает на
локальном сокете/порту; nginx на `@mirror` вместо `proxy_pass https://upstream`
делает `proxy_pass http://127.0.0.1:<pull-port>`.

### 7.1. Алгоритм sidecar'а (на запрос `/<hash>.narinfo`)

```
1. h ← hash из URL
2. если nix path-info <h> есть в локальном сторе (или nix-serve отдал 200):
       вернуть «уже локально» → nginx отдаёт через nix-serve-ng (пере-подписано)
3. для каждого upstream по порядку:
       narinfo ← GET <upstream>/<h>.narinfo
       если 200: разобрать StorePath: /nix/store/<h>-<name>
                 nix copy --from <upstream> /nix/store/<h>-<name>   # импорт в стор
                 goto 2  (теперь локально → nix-serve-ng отдаст пере-подписанно)
4. все upstream 404 → вернуть 404
```

### 7.2. Сложности Tier 2 (почему это roadmap)

- **hash → store-path**: из URL есть только `<hash>`, а `nix copy --from` хочет
  полный путь. Решение: парсить `StorePath:` из narinfo upstream'а (шаг 3).
- **Конкурентность**: один путь могут запросить одновременно → нужна per-hash
  блокировка (flock по `$hash`), иначе дублируем `nix copy`. (В Tier 1 это даёт
  бесплатно `proxy_cache_lock`.)
- **Гарантии_consistency**: narinfo отдаётся nix-serve-ng **после** того, как
  путь реально импортирован; нужен барьер (sidecar отвечает 200/302 на nginx
  только по факту успешного `nix copy`).
- **GC-взаимодействие**: импортированные пути становятся достижимыми и подпадают
  под существующий `nix.gc` (30 дней) — это и плюс (единое управление), и минус
  (активно-запрашиваемые upstream-пути могут вытеснить локально собранные при
  нехватке места — нужен мониторинг `max-jobs`/диска).

### 7.3. Альтернатива: заменить `nix-serve-ng` на Attic

[Attic](https://github.com/zhaofengli/attic) — nix-кэш-сервер с дедупликацией,
компрессией и (в актуальных версиях) поддержкой **upstream substituter'ов** —
т.е. нативным pull-through. Если single-key trust станет жестким требованием,
а Tier 2 sidecar окажется дороже поддержки — рассмотреть миграцию
`nix-serve-ng` → `atticd` отдельной спекой (это смена backend'а кэша, влияет на
`cache.nix` + consumer wiring, **не** делается в рамках 0002).

---

## 8. Поставка доверия (consumer-side)

### 8.1. Tier 1 — доверие nixtache **и** upstream

Зеркалируемые narinfo сохраняют upstream-подпись → потребитель обязан держать
в `trusted-public-keys` **и** публичный ключ nixtache, **и** ключи всех
`mirror.upstreams`. Это не новая нагрузка: потребитель и так уже доверяет
`cache.nixos.org-1:…` (см. `default.nix` `nixSettings`).

Consumer-side проводка (на каждой машине-клиенте кэша):

```nix
nix.settings = {
  substituters        = [ "https://bincache.zinzaguras.ru" "https://cache.nixos.org/" ];
  trusted-public-keys = [
    "bincache.zinzaguras.ru-1:…<публичный ключ nixtache>…"
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  ];
};
```

> `bincache` идёт **первым** → локальные/зеркальные пути берутся из nixtache;
> `cache.nixos.org` остаётся фолбэком (на случай падения bincache).

### 8.2. Публичный ключ nixtache как опция

Чтобы consumer мог взять ключ nixtache из модуля (а не хардкодить), добавляется
**необязательная** опция `cache.publicKey` (`nullOr str`, default `null`) —
публичная половина `secrets.cachePrivateKey`. Модуль её **не использует внутри
себя** (nix-serve-ng подписывает приватным); она нужна только как
«self-documenting» значение для consumer'а (пример генерации
`trusted-public-keys`). Если `null` — потребитель вставляет ключ вручную
(как сегодня).

### 8.3. Tier 2 — доверие **только** nixtache

При `mirror.resign = true` все narinfo пере-подписаны ключом nixtache →
consumer'у достаточно одного `cache.publicKey` в `trusted-public-keys`. Это
главный UX-выигрыш Tier 2.

---

## 9. Безопасность

- **R8 (SSRF):** upstream-список зафиксирован в опциях модуля; nginx ходит
  **только** на `mirror.upstreams[*].url`. Никакого вывода URL из запроса.
- **Подпись:** Tier 1 не ослабляет trust-модель — потребитель явно перечисляет
  доверенные ключи; подделать narinfo без приватного upstream-ключа нельзя.
- **Диск/DoS:** публичный кэш может быть target'ом запросов на раздувание —
  `max_size` + `inactive` (R6) ограничивают дисковое потребление; `proxy_cache_lock`
  (R7) предотвращает thundering-herd. Рекомендуется мониторинг заполнения
  `cacheDir`.
- **Ключ подписи:** по-прежнему `types.path`, монтируется read-only; mirror
  (Tier 1) его вообще не касается; Tier 2 использует только для пере-подписи
  уже-импортированных путей (приватник не покидает контейнер).
- **Чистый upstream-fallback:** при падении upstream'а локальные пути
  продолжают отдаваться (R9) — кэш не становится «тёмным» при отсутствии сети.

---

## 10. Тестовое покрытие (`tests/runner.nix`)

По правилу репо — каждая новая опция/поведение покрывается сценарием
(pure-eval: собирается `nixosSystem` и проверяются `config.*`):

| Сценарий | Что проверяем |
|---|---|
| `mirror.enable = false` (default) | nginx-vhost идентичен сегодняшнему (один `location /` → `proxy_pass`); `proxy_cache_path` отсутствует |
| `mirror.enable = true`, дефолтный upstream | есть `proxy_cache_path` с `max_size`/`inactive` из опций; vhost содержит `@mirror` location; `proxy_cache_lock on` |
| Кастомные `upstreams` / `maxSize` / `cacheDir` | значения попадают в сгенерированный nginx-конфиг |
| `mirror.resign = true` | assertion-fail «Tier-2 не реализован, см. спеку 0002 §7» (до имплементации Tier 2) |
| `mirror.upstreams[].url` пустой | assertion-fail «url обязателен» |
| `cache.publicKey` задан | попадает в вывод/документацию (не во внутренний конфиг) |
| local-first | в vhost `proxy_pass` на LOCAL стоит **до** `@mirror`-фолбэка (через `error_page 404 = @mirror`) |

---

## 11. Артефакты и этапы

### Артефакты в `nixtache`

| Артефакт | Назначение | Статус |
|---|---|---|
| `modules/runner/mirror.nix` | Опции `cache.mirror.*` + host-side расширение nginx-vhost (`proxy_cache_path` + `@mirror` location) | НОВОЕ |
| `modules/runner/types.nix` | `mirrorUpstreamType` (подмодуль §5.2) | правка |
| `modules/runner/default.nix` | `imports += [ ./mirror.nix ]` | правка |
| `modules/runner/cache.nix` | добавить `cache.publicKey` (`nullOr str`, default `null`); остальное без изменений | правка |
| `tests/runner.nix` | + сценарии mirror on/off/edge (§10) | правка |
| `packages.optionsMarkdown` | авто-включит новые опции (`services.nixtache.runner.cache.mirror.*`) | без правок |
| `README.md` / `AGENTS.md` | раздел «Transitive cache» + consumer trust-проводка (§8) | правка |

### Этапы

1. **Контракт модуля** — `mirrorUpstreamType` + `cache.mirror.*` + `cache.publicKey`;
   assertion'ы (`resign`, пустой `url`); тесты (§10).
2. **nginx-routing** — сгенерировать `proxy_cache_path` + local-first vhost с
   `@mirror`; smoke-check `nix eval` / `nix build .#checks…`.
3. **Tier 1 на стенде** — поднять consumer-машину с `bincache` первым
   substituter'ом; запросить свежий путь → убедиться, что второй запрос идёт из
   `cacheDir` (логи nginx `HIT`/`MISS`).
4. **Документация consumer-side** — пример `substituters`/`trusted-public-keys`
   (§8.1) в README.
5. *(Roadmap)* **Tier 2** — sidecar-демон + `mirror.resign = true`; отдельный
   этап после оценки (§7.2) либо решение в пользу Attic (§7.3).

### Контрольная точка (checkpoint)

> Спека — это **план** инфраструктурного изменения, затрагивающего публичный
> nginx + trust-модель кэша (security-relevant). **До правок модуля**
> (`mirror.nix`/`types.nix`/`cache.nix`) жду явного подтверждения выбранного
> подхода:
> - Tier 1 (nginx pull-through mirror) как v1 — **да/нет**;
> - default `mirror.enable` = `false` (опциональность) — **да/нет**;
> - Tier 2 (`resign`) оставить roadmap'ом или делать сразу — **выбор**;
> - альтернатива Attic (§7.3) — рассмотреть сейчас или отложить.

---

## 12. Открытые вопросы

| Q | Вопрос | Вариант |
|---|---|---|
| Q1 | Tier 1 vs Tier 2 как первая итерация | По умолчанию Tier 1 (простота, 0 своего runtime); Tier 2 — когда нужен single-key trust на всём флоте |
| Q2 | Набор default `upstreams` | `cache.nixos.org` только, либо сразу включить SJTU/USTC/cernet (как в `nixSettings`) — но зеркала могут отставать; решить |
| Q3 | `max_size` по умолчанию | `100g` — уперётся в диск сервера; уточнить по месту (server disk) |
| Q4 | Подпись зеркальных narinfo: пере-подписывать силами nginx? | Нет (nginx не умеет); Tier 2 sidecar или Attic. Tier 1 = проксировать как есть |
| Q5 | Мониторинг наполнения `cacheDir` | Не в scope v1; обозначить node_exporter/алёрт на заполнение отдельно |
| Q6 | `cache.publicKey` — делать опцией или держать external? | Опция `nullOr str` (self-documenting); если `null` — consumer вставляет сам (как сегодня) |

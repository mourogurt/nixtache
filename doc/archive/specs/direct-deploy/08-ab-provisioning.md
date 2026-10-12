# 08 — A/B partition provisioning (init, migration, resize)

> Целевой модуль: `services.nixtache.deploy-target.ab.partitions` (новая
> секция в `modules/deploy-target/ab.nix`, отдельный `ab-provision.nix`).
>
> **Проблема:** `06-ab-image.md` описывает КАК собирается образ и КАК sysupdate
> пишет слот B. Но не описывает, КАК физически появляются A/B слоты на диске при
> первой установке или миграции. В тесте это делалось одноразовой службой
> `ab-disk-init` (sgdisk вручную). В бою нужен декларативный модуль: задаешь
> размеры — он гарантирует layout при загрузке.
>
> **Статус:** ✅ реализовано (`modules/deploy-target/ab-provision.nix`, тесты
> `ab-contract` / `ab-provision-vm` зелёные). Модель меток — sysupdate-native:
> записанный слот = `nix-store_<v>`, свободный слот = `_empty` (хардкод в
> systemd-sysupdate, см. §2).

## Контекст: что уже есть

| Компонент | Где | Что делает |
|---|---|---|
| `modules/ab-image/default.nix` | build-time | repart-image: UKI + squashFS slots + sysupdate transfers. Генерирует `system.build.image` и `system.build.sysupdate-package`. |
| `modules/deploy-target/ab.nix` | runtime | polkit + gating-unit (idle-wait). Проверяет, что `systemd.sysupdate` включён. |
| `systemd-sysupdate` | runtime | Берёт готовые GPT-партиции (`nix-store_<v>` + `_empty`), пишет в `_empty`, переименовывает её в `nix-store_<v>`; при vacuum старой версии переименовывает обратно в `_empty`. **НЕ создаёт партиции**. |
| `systemd-repart` | boot-time | Может расти/добавлять партиции на живом диске. НЕ умеет сжимать или двигать. |

**Пробел:** никто не создаёт GPT-партиции на диске таргета при первой установке
или миграции. sysupdate требует, чтобы слоты **уже существовали**. Этот модуль
заполняет пробел.

---

## 1. Миграция с NixOS без A/B на A/B слоты

### Начальное состояние (типичный NixOS)

```
/dev/nvme0n1
├── p1: ESP (vfat, ~512M)         ← /boot
├── p2: root (ext4/btrfs, весь остаток диска)
│         /nix/store живёт ЗДЕСЬ (на root FS, не отдельная партиция)
└── (нет A/B слотов)
```

### Целевое состояние (A/B)

```
/dev/nvme0n1
├── p1: ESP (vfat, ~512M)         ← /boot (UKI + boot-counting)
├── p2: root (ext4/btrfs)         ← persistent state: /etc, /var, /home
├── p3: nix-store_1 (squashFS/erofs, ro) ← активный слот (v1)
├── p4: _empty (свободный слот)          ← сюда sysupdate запишет v2
└── p5..: data partitions (опц., extraPartitions)
```

Ключевое отличие: `/nix/store` переезжает с root-FS на **отдельные read-only
squashFS партиции** (A/B). Root остаётся persistent (ext4/btrfs), но больше не
содержит `/nix/store` — он монтируется из активного слота.

### Три сценария миграции

| Сценарий | Данные | Когда | Дowntime |
|---|---|---|---|
| **A. nixos-anywhere** (recommended) | **Потеря** disk (backup→restore) | Миграция production на A/B; место на диске недостаточно для in-place; root-FS нересайзабель | Полный (kexec+reinstall по SSH, ~15 мин) |
| **B. In-place grow** | **Сохранение** root + /home | На диске есть неразмеченное место после root-партиции (или root можно сжать) | ~10 минут (resize + add partitions) |
| **C. Second disk** | **Полное сохранение** | Есть второй физический диск; A/B слоты размещаются на нём | Минимальный (add disk, migrate mount) |

#### A. Wipe-and-reinstall (nixos-anywhere)

**Recommended-путь для миграции production-сервера на A/B.**
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) автоматизирует
полный цикл wipe→repartition→install **по SSH, без физического доступа** — через
kexec (загрузка в RAM → диск свободен → disko переразмечает).

**Как это работает (3 фазы, 0 ручных шагов):**

```
  Оператор (desktop)                                    Target (server)
  ─────────────────                                     ────────────────
  nixos-anywhere ──SSH──►
                          1. kexec: грузит NixOS-installer в RAM
                             (kernel+initrd+squashfs, ~1.5 GB RAM)
                             → старая ОС выгружена, диск СВОБОДЕН
                                         │
                          2. disko: destroy→format→mount
                             → стирает partition table
                             → создаёт новый layout (ESP+root+slots)
                                         │
                          3. nixos-install: копирует closure в /mnt
                                         │
                          4. reboot → грузится новая A/B система ◄── автоматический ребут
```

**Команда (одна строка с desktop):**

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#server-ab-image \
  --target-host root@server \
  --disko-mode destroy,format,mount
```

Где `server-ab-image` — NixOS-конфиг с **disko-layout** (ESP + root + nix-store
slots A/B) + `nixosModules.ab-image` + `nixosModules.deploy-target`.

**Что надо приготовить (consumer):**

1. **disko-конфиг** — декларативное описание диска (вместо или в дополнение к
   `image.repart`). disko и repart описывают один и тот же layout, но для разных
   целей: disko — для install-time (нарезать живой диск), repart — для build-time
   (собрать образ для sysupdate). Можно [переиспользовать общую структуру](https://github.com/nix-community/disko/blob/master/docs/reference.md).
2. **Backup** — `/home`, `/var/lib/...`, `/etc` конфиги. disko `destroy` сносит
   partition table целиком — **всё** на объявленных дисках теряется.
3. **Restore** — после установки, `scp`/`rsync` данных на новый root.

**Условие применимости:**
- ≥1.5 GB RAM (installer живёт в RAM; для ≤1 GB — `--no-disko-deps`).
- Target доступен по SSH (wired/LAN/VPN; wifi не поддерживается).
- x86_64 / aarch64 (преbuilt kexec-образы; для других arch — `--kexec <custom>`).

**Ограничения:**
- **disko работает на уровне ДИСКА, не партиции.** Нельзя «сохрани партицию X,
  затри Y» на одном диске. Для сохранения данных — либо отдельный диск (не
  объявленный в `disko.devices`), либо backup→restore.
- SSH host keys меняются после install (`--copy-host-keys` сохраняет).
- `--generate-hardware-config nixos-facter <path>` — авто-генерация hardware-config
  во время install (опционально, для flakes без ручного hardware.nix).

**Модульная поддержка:** nixtache не генерирует disko-конфиг автоматически.
Consumer пишет disko-layout под свою машину (disk sizes, disk device path,
partition sizes — машинно-специфичные). nixtache обеспечивает только A/B-specific
опции (slotSize, sysupdate transfers, boot-counting). См. §4 "опции" ниже.

**Почему не dd / USB:**
- `dd` требует физического доступа (USB, KVM IPMI) и ручных шагов.
- nixos-anywhere — полностью по SSH, идемпотентный, декларативный (disko), и
  автоматически копирует closure. Единственный «ручной» шаг — подтвердить что
  данные стёрты будут (backup сделан).

#### B. In-place grow

Самый интересный сценарий. Диск уже разбит, но есть свободное место.

```
ДО:                          ПОСЛЕ:
/dev/nvme0n1                 /dev/nvme0n1
├── p1: ESP    512M          ├── p1: ESP    512M
├── p2: root   40G           ├── p2: root   40G (не трогаем)
├── (free)    ~20G           ├── p3: nix-store_1  2G  ← add
│                            ├── p4: _empty       2G  ← add
│                            └── (free)          ~16G
```

**Последовательность (initrd, до монтирования root):**

1. **Проверить:** есть ли уже A/B слоты (GPT labels `nix-store_[0-9]` / `_empty`).
   - Да → пропустить, ничего не делать.
   - Нет → продолжить.
2. **Проверить:** есть ли свободное место после последней партиции.
   - `sgdisk -p /dev/nvme0n1` → `end sector of last partition < disk end`.
3. **Создать слоты** (если место есть):
   ```bash
   sgdisk --new=3:0:+2G --typecode=3:8300 --change-name=3:nix-store_1 /dev/nvme0n1
   sgdisk --new=4:0:+2G --typecode=4:8300 --change-name=4:_empty /dev/nvme0n1
   ```
4. **Записать slot A** из текущего образа — **вне модуля** (dd из live-USB,
   `nixos-anywhere`, или initial deploy через action `_abImage`): на первой
   загрузке после миграции образ ещё не собран (appliance, `nix.enable=false`),
   поэтому provisioning-модуль слот A не заполняет.
5. **Обновить fstab:** `/nix/store` монтируется из `/dev/disk/by-partlabel/nix-store_1`.
6. **Перезагрузка.**

**Условие применимости:** на диске есть `>= 2 × slotSize` неразмеченного места
после последней партиции. Root-FS не нужно сжимать.

**Если свободного места НЕТ (root занимает весь диск):**

Нужно **сжать root-FS**. **Универсальной утилиты для этого в Linux не существует**
— каждый тип FS имеет свой инструмент, а некоторые сжиматься в принципе не умеют:

| ФС | Сжатие | Инструмент | Онлайн? |
|---|---|---|---|
| ext4 | ✅ | `resize2fs` | ❌ offline (unmount) |
| btrfs | ✅ | `btrfs filesystem resize` | ✅ online |
| f2fs | ✅ | `resize.f2fs` | ❌ offline |
| **xfs** | ❌ | **невозможно** (design limitation) | — |
| **zfs dataset** | ❌ | **невозможно** (only grow) | — |

Ни `parted resizepart`, ни `systemd-repart`, ни `growpart` не умеют сжимать FS.
Эти инструменты меняют только GPT-запись (partition table), но не содержимое FS —
без предварительного сжатия FS это ведёт к corruption. `systemd-repart`
поддерживает **только grow** (документированное ограничение).

**Модуль НЕ делает shrink автоматически** (каждый тип FS — свой tool, некоторые
невозможны). Если места нет — assertion:
```
ab.partitions.autoInit = true, but disk has no free space for A/B slots
(needs 2 × slotSize = 4G after the last partition; found 0).
Options:
  1. Shrink root manually (ext4: resize2fs offline; btrfs: btrfs filesystem
     resize online; xfs/zfs: impossible — see doc/specs/direct-deploy/08-ab-provisioning.md §B).
  2. Use nixos-anywhere for a full wipe-and-reinstall (scenario A — by SSH, no
     physical access needed; recommended for production servers).
  3. Add a second disk and put A/B slots there (scenario C).
  4. Set ab.partitions.autoInit = false and provision manually.
```

#### C. Second disk

A/B слоты на отдельном диске (`/dev/nvme1n1`). Root и data остаются на
`/dev/nvme0n1`.

```
/dev/nvme0n1 (не трогаем)      /dev/nvme1n1 (новый, A/B)
├── p1: ESP                     ├── p1: nix-store_1  2G
├── p2: root                    └── p2: _empty        2G
└── /nix/store ← symlink/mount     ↑
                                   /nix/store монтируется ОТСЮДА
```

**Условие применимости:** есть второй диск. Самый безопасный путь (оригинальный
диск не трогается вообще).

Модуль поддерживает через `ab.partitions.disk = "/dev/nvme1n1"`.

---

## 2. Проверка: нужны ли A/B слоты (detection)

### При каждой загрузке

Oneshot-сервис `nixtache-ab-provision.service` (до `systemd-sysupdate.timer`)
проверяет состояние диска:

```bash
#!/bin/bash
# nixtache-ab-provision — idempotent A/B slot provisioning.
set -euo pipefail

DISK="${1:-auto}"
SLOT_SIZE="<configured slotSize>"   # из NixOS опции

# ── 1. Найти диск ────────────────────────────────────────────────────
if [ "$DISK" = "auto" ]; then
  # Найти диск, на котором живёт root (через findmnt → lsblk).
  DISK=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p$//')
  # /dev/nvme0n1p2 → /dev/nvme0n1
fi

# ── 2. Проверить состояние A/B слотов ───────────────────────────────
# Два состояния (stateless — по GPT label count, без state-файла):
#   Normal:   ≥1 slot label (nix-store_[0-9] или _empty)  → check sizes
#   Missing:  0 slot labels                               → migration
# Оба семейства меток считаются слотами: `nix-store_<v>` — записанный слот
# (sysupdate ставит такую метку при записи), `_empty` — свободный слот
# (хардкод sysupdate: именно эту метку он ищет как цель для записи и
# возвращает её при vacuum старой версии). Пост-wipe состояние отдельно
# не нужно: wipe пересоздаёт ту же пару nix-store_1 + _empty, что и
# autoInit, поэтому следующий boot — это Normal с совпадающими размерами.
has_slots=$(lsblk -no PARTLABEL "$DISK" 2>/dev/null | grep -cE 'nix-store_[0-9]|_empty' || true)

if [ "$has_slots" -ge 1 ]; then
  echo "A/B slots present (normal) — checking sizes..."
  # ── 3. Проверить размер (см. §3 ниже) ──
  actual_size=$(lsblk -bno SIZE,PARTLABEL "$DISK" | \
    awk '/nix-store_[0-9]|_empty/{print $1; exit}')
  # ... compare with SLOT_SIZE ...
  exit 0
fi

# ── 4. Слотов нет — миграция ─────────────────────────────────────────
if [ "${NIXTACHE_AB_AUTO_INIT:-0}" != "1" ]; then
  echo "::error:: A/B slots missing on $DISK and autoInit=false."
  echo "Set services.nixtache.deploy-target.ab.partitions.autoInit = true"
  echo "or provision manually: see doc/specs/direct-deploy/08-ab-provisioning.md"
  exit 1   # boot fails (provision is wantedBy sysupdate)
fi

# ── 5. Проверить свободное место ─────────────────────────────────────
last_end=$(sgdisk -p "$DISK" | awk '/^ *[0-9]/{end=$3} END{print end}')
disk_end=$(blockdev --getsz "$DISK")
free_sectors=$((disk_end - last_end))
free_bytes=$((free_sectors * 512))
needed_bytes=$(numfmt --from=auto "$SLOT_SIZE")
needed_bytes=$((needed_bytes * 2))   # два слота

if [ "$free_bytes" -lt "$needed_bytes" ]; then
  echo "::error:: Not enough free space for A/B slots: need $needed_bytes bytes"
  echo "(2 × $SLOT_SIZE), have $free_bytes bytes after last partition."
  echo "Shrink root manually or use wipe-and-reinstall."
  exit 1
fi

# ── 6. Создать слоты ─────────────────────────────────────────────────
# Найти следующий свободный номер партиции.
next_part=$(sgdisk -p "$DISK" | awk '/^ *[0-9]/{n=$1+1} END{print n}')
sgdisk --new="${next_part}:0:+${SLOT_SIZE}" \
       --typecode="${next_part}:8300" \
       --change-name="${next_part}:nix-store_1" "$DISK"
sgdisk --new="$((next_part+1)):0:+${SLOT_SIZE}" \
       --typecode="$((next_part+1)):8300" \
       --change-name="$((next_part+1)):_empty" "$DISK"
udevadm settle

# ── 7. Записать slot A из текущего образа ────────────────────────────
# squashFS из storePaths системы → уже собран как system.build.image.
# На первой загрузке после миграции образ ещё не собран (nix.enable=false
# на appliance!). Поэтому slot A записывается ВНЕ модуля — dd из live-USB
# или deploy через action _abImage в режиме "initial provisioning".

echo "A/B slots created on $DISK"
```

### Логика принятия решений

```
ab.partitions.enable?
│
├─ no ──────────────────────────────────────────► skip (всё ручное)
│
└─ yes
    │
    ├── slot type = "regular-file"?
    │   │
    │   └─ yes ────────────────────────────────► skip provision
    │                                              (sysupdate сам создаёт файлы
    │                                               при первом systemd-sysupdate)
    │
    └── slot type = "partition"
        │
        ├── slot labels (nix-store_[0-9] или _empty) ≥1?
        │   │
        │   ├─ yes ──► размер совпадает с slotSize?
        │   │           │
        │   │           ├─ yes ─────────────────► OK ✓ (sysupdate работает)
        │   │           │
        │   │           └─ no ─► onSizeMismatch?
        │   │                     │
        │   │                     ├─ "error" ───► assertion: блокирует sysupdate
        │   │                     │
        │   │                     └─ "wipe" ────► удалить оба слота
        │   │                                      → создать заново (nix-store_1 + _empty)
        │   │                                      → OK ✓ (sysupdate заполнит _empty на next deploy)
        │   │
        │   └─ no ──► MISSING: autoInit?
        │              │
        │              ├─ true ─► свободное место?
        │              │           │
        │              │           ├─ yes ─► создать слоты (nix-store_1 + _empty)
        │              │           │         → OK ✓
        │              │           │
        │              │           └─ no ──► assertion: "нет места"
        │              │
        │              └─ false ─► assertion: "слотов нет"
```

---

## 3. Изменение размера A/B слотов

### Проблема

`slotSize` в конфиге изменился (напр. `2G → 4G`). Что делать с существующими
партициями?

**Ограничения:**
- squashFS — read-only FS. Нельзя resize «на месте».
- GPT-партиции можно удалить и создать заново, но это **деструктивно** для
  содержимого слота.
- `systemd-repart` умеет расти, но НЕ умеет сжимать.
- Slot A содержит текущую систему — его потеря = невозможность загрузиться
  (если только boot-counting не откатится, но откатываться некуда — другого
  слота нет).

### Политика: `onSizeMismatch`

```nix
services.nixtache.deploy-target.ab.partitions = {
  onSizeMismatch = "error";
  # "error"   — assertion при загрузке: блокирует, требует ручного вмешательства.
  # "wipe"    — стирает ОБА слота и пересоздаёт. Требует немедленного deploy
  #             (через action _abImage или dd), иначе система не загрузится
  #             (нет валидного slot A).
};
```

#### `onSizeMismatch = "error"` (дефолт, безопасный)

```
[AB-PROVISION] Size mismatch: slot A is 2G, configured slotSize is 4G.
  To change slot size, both A/B slots must be wiped and recreated.
  This is DESTRUCTIVE — slot A (current system) will be lost.
  Set onSizeMismatch = "wipe" to proceed automatically, or:
    1. Deploy new image via action _abImage (mode=ab-image) to the new-size slots
    2. Reboot into the new slot A
  See doc/specs/direct-deploy/08-ab-provisioning.md §3.
```

Boot **не блокируется** (система грузится из старого slot A), но обновления
**останавливаются**: provision-юнит логирует mismatch, **маскирует**
`systemd-sysupdate.service` (`systemctl mask --runtime` — plain mask не может
перезаписать NixOS-managed symlink юнита; runtime-маска в /run, а provision-юнит
каждую загрузку перемаскирует ДО старта sysupdate) и завершается с ошибкой.
Разрешение — ручное: поправить `slotSize` (или переключиться на
`onSizeMismatch = "wipe"`), пересобраться, затем
`systemctl unmask --runtime systemd-sysupdate.service && systemctl start nixtache-ab-provision.service`.

#### `onSizeMismatch = "wipe"` (автоматический, деструктивный)

```
[AB-PROVISION] Size mismatch: slot A is 2G, configured slotSize is 4G.
  onSizeMismatch = "wipe" — recreating BOTH slots.
  Slot A will be empty after this — a deploy is REQUIRED before reboot!
```

1. Удалить обе slot-партиции (все `nix-store_*` и `_empty`).
2. Создать две новые партиции с новым `slotSize`.
3. Label: `nix-store_1` + `_empty` (та же пара, что создаёт autoInit и что
   поставляет собранный образ).
4. sysupdate при следующем deploy пишет новую версию в `_empty` и
   переименовывает её в `nix-store_<v>` (штатный механизм sysupdate).

**Detection на следующем boot'е** (§2): пара `nix-store_1 + _empty` уже
существует → **Normal** → размеры совпадают (wipe создал их ровно по
slotSize) → provision no-op (exit 0). Отдельного post-wipe состояния нет —
именно это делает wipe идемпотентным.

> **Note:** слот `nix-store_1` после wipe пуст по содержимому, но несёт
> версионную метку — sysupdate считает v1 «уже установленной». Поэтому
> post-wipe деплой должен нести **новый** `imageVersion` (естественный поток:
> деплоится свежее образ, а не v1 повторно).

### Порядок смены slotSize в бою (recommended)

1. **Изменить `slotSize` в конфиге** (новое значение).
2. **Деплоить новый образ** через action `_abImage` — он собирается с новым
   `storeSize`, `sysupdate-package` имеет правильный размер.
3. **onSizeMismatch = "error"**: provision-юнит видит mismatch, маскирует
   sysupdate (`systemctl mask`) и падает с сообщением о разрешении конфликта.
4. **Вручную:** либо:
   - `onSizeMismatch = "wipe"` → перезагрузка → оба слота пересоздаются →
     sysupdate ставит v_new в `_empty` → reboot в новый активный слот.
   - Или wipe-and-reinstall (dd нового образа на диск).

---

## 4. Опции модуля

### Полное дерево опций

```nix
services.nixtache.deploy-target.ab.partitions = {
  enable = true;
  # Запускать nixtache-ab-provision.service при загрузке (перед
  # systemd-sysupdate). false: полностью отключить provision — слоты должны
  # быть созданы вручную (nixos-anywhere, sgdisk, dd).

  # ── Слоты (per-slot: где и как хранится) ────────────────────────────
  # Каждый слот независим: тип хранения (partition/file) + расположение.
  # Assert: type у обоих слотов ДОЛЖЕН совпадать (sysupdate требует
  # одинаковый Target.Type для всех instances одного transfer).
  slot_a = {
    type = "partition";
    # "partition"  — GPT-партиция на блочном устройстве (production).
    # "regular-file" — файл в директории (тесты / нет GPT / LVM-loopback).

    storage = "auto";
    # type = "partition":  блочное устройство. "auto" = определить по root FS
    #   (findmnt → lsblk). "/dev/nvme0n1" — явно. "/dev/nvme1n1" — second disk.
    # type = "regular-file": директория. "/var/lib/nixtache/ab-slots/".

    label = "nix-store_1";
    # type = "partition":  GPT partition label (sgdisk --change-name).
    # type = "regular-file": игнорируется (имя файла = MatchPattern).
  };

  slot_b = {
    type = "partition";       # должен совпадать с slot_a.type (assert)
    storage = "auto";         # может отличаться от slot_a.storage (разные диски)
    label = "_empty";          # свободный слот; sysupdate запишет его и переименует в nix-store_<v>
  };

  # ── Размер (общий для обоих слотов) ────────────────────────────────
  slotSize = "2G";
  # Размер каждого слота (A и B одинакового размера — squashFS constraint).
  # ЕДИНЫЙ ИСТОЧНИЧНИК размера: при co-import ab-image его storeSize
  # НАСЛЕДУЕТ slotSize как default (явный storeSize ≠ slotSize → assert A2).
  # Принимает:
  #   Абсолютный:  "2G", "512M", "1024" (байты), "2GiB"
  #   Процент:     "10%" — 10% от размера устройства (storage).
  #                Вычисляется в provision-script:
  #                  bytes = floor(disk_size * pct / 100)
  #                Для "auto" storage — от размера root-диска.
  # ab-image.storeSize наследует это значение (default), явное расхождение → assert A2.
  # ВЛИЯЕТ НА: provision (создание партиций). repart-image берёт размер из
  # ab-image.storeSize (build-time).

  # ── Автоинициализация ─────────────────────────────────────────────
  autoInit = false;
  # false (дефолт): если слотов нет → assertion (fail с понятным сообщением).
  # true: если слотов нет и есть место → создать автоматически (sgdisk).
  # Только для type = "partition". Для type = "regular-file" игнорируется
  # (sysupdate сам создаёт файлы при первом запуске).
  # ВНИМАНИЕ: autoInit + нет slot A = система не загрузится из A/B!
  # autoInit имеет смысл только при second-disk сценарии или если
  # slot A записывается в том же initrd-проходе.

  # ── Политика при несовпадении размера ──────────────────────────────
  onSizeMismatch = "error";
  # "error" (дефолт): блокирует sysupdate, пишет assertion-сообщение.
  # "wipe": стирает оба слота и пересоздаёт. ОПАСНО — slot A теряется.

  # ── Защита данных (только type = "partition") ─────────────────────
  protectedLabels = [ "root" "esp" "boot" ];
  # GPT partlabels, которые provision-сервис НИКОГДА не трогает.
  # Дополнительный assert: если wipe требуется для партиции с label из
  # этого списка → fail (не wipe).

  # ── OTA source (откуда target тянет staged-образы) ────────────────
  source = "https://runner.example.com/ab-stage/myhost";
  # remote: "http(s)://..." → Source Type=url-file; local: "/abs/dir" →
  # file:// + regular-file (self-deploy). null = placeholder (Source
  # переопределяется вручную). Тип деплоя выводится из схемы.

  imageId = null;
  # Image id для MatchPattern (`<imageId>_@v.nix-store.raw`). null = из
  # ab-image.imageId при co-import, иначе "nixtache". Задать явно на
  # target'ах БЕЗ ab-image (plain host, обновляемый извне).

  # ── Верификация подписи (deployer=priv, target=pub) ───────────────
  verify = false;
  # Transfer.Verify. Избыточна при заданном ключе (ключ ⇒ verify, как в
  # ab-image). true без ключа → assertion A5.
  publicKeyFile = null;  # путь к OpenPGP PUBLIC ключу (binary/armored)
  publicKey = null;      # inline armored (альтернатива; вместе с
                         # publicKeyFile → assertion A6, только ОДИН)
  # Ключ ставится как /etc/systemd/import-pubring.pgp (+ /usr/lib symlink).
  # При co-imported ab-image с его ключом — pubring ab-image авторитетен.

  # ── UKI transfer (только без co-imported ab-image) ────────────────
  bootTarget = "auto";
  # "auto" = ESP /EFI/Linux через $BOOT-autodiscovery (PathRelativeTo="boot",
  # как в ab-image). Иная строка = абсолютная директория (plain host /
  # тестовая VM без ESP). Модуль также сам включает systemd.sysupdate
  # (mkDefault true) — ручной `systemd.sysupdate = {...}` не нужен.
};
```

> **Примечание:** опция `mountPoint` убрана — монтирование активного слота
> это job `ab-image` модуля (`fileSystems."/nix/store" = cfgForLabel "nix-store"`),
> НЕ provision модуля. Provision только создаёт/проверяет партиции (sgdisk).
> Если бы оба модуля генерировали `fileSystems."/nix/store"` — duplicate-definition.

### Что модуль выводит из slot_a/slot_b (производные значения)

> **Важно:** ab-provision — **единственный автор** `systemd.sysupdate.transfers`
> когда `partitions.enable = true`. ab-image ставит `mkDefault` (fallback для
> standalone-тестов без provision). При конфликте приоритетов — provision
> выигрывает (normal priority > mkDefault).

```nix
# Module-internal: provision service (только type = "partition")
config.systemd.sysupdate.transfers = mkIf cfg.enable (let
  # Если оба слота на одном storage → один transfer, InstancesMax = 2.
  # Если на разных → два transfer, каждый InstancesMax = 1.
  # (ab-image ставит mkDefault → overridden здесь при partitions.enable=true)
config.systemd.services.nixtache-ab-provision = mkIf (cfg.enable && slot_a.type == "partition") {
  description = "Provision A/B nix-store partition slots";
  before = [ "systemd-sysupdate.service" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  path = with pkgs; [ gptfdisk util-linux systemd ];
  environment = {
    NIXTACHE_AB_SLOT_A_DISK   = slot_a.storage;   # "auto" | "/dev/nvme0n1"
    NIXTACHE_AB_SLOT_B_DISK   = slot_b.storage;
    NIXTACHE_AB_SLOT_A_LABEL  = slot_a.label;      # "nix-store_1"
    NIXTACHE_AB_SLOT_B_LABEL  = slot_b.label;      # "_empty"
    NIXTACHE_AB_SLOT_SIZE     = cfg.slotSize;
    NIXTACHE_AB_AUTO_INIT     = if cfg.autoInit then "1" else "0";
    NIXTACHE_AB_ON_MISMATCH   = cfg.onSizeMismatch;
  };
  script = provisionScript;
};

# Module-internal: sysupdate transfers (derived from slot type + storage)
# Если оба слота на одном storage → один transfer, InstancesMax = 2.
# Если на разных → два transfer, каждый InstancesMax = 1.
config.systemd.sysupdate.transfers = let
  # Общий builder для transfer
  mkTransfer = disk: instances: {
    Source = {
      Path = srcPath;   # из ab-image (file:// или http://)
      Type = srcType;
      MatchPattern = [ "${imageId}_@v.nix-store.raw" ];
    };
    Target = {
      inherit instances;
      Path = if slot_a.type == "partition" then disk else disk; # disk или dir
      MatchPattern = if slot_a.type == "partition" then "nix-store_@v" else "${imageId}_@v.nix-store.raw";
      Type = if slot_a.type == "partition" then "partition" else "regular-file";
    } // (lib.optionalAttrs (slot_a.type == "partition") {
      MatchPartitionType = "linux-generic";
      ReadOnly = "yes";
    });
    Transfer.Verify = if verify then "yes" else "no";
  };
in
  if slot_a.storage == slot_b.storage then
    { "10-nix-store" = mkTransfer slot_a.storage 2; }
  else
    { "10-nix-store-a" = mkTransfer slot_a.storage 1;
      "10-nix-store-b" = mkTransfer slot_b.storage 1; };
```

### Примеры конфигураций

**Production (оба слота — партиции на одном диске):**
```nix
slot_a = { type = "partition"; storage = "auto";      label = "nix-store_1"; };
slot_b = { type = "partition"; storage = "auto";      label = "_empty";      };
```

**Second disk (оба слота — на отдельном диске):**
```nix
slot_a = { type = "partition"; storage = "/dev/nvme1n1"; label = "nix-store_1"; };
slot_b = { type = "partition"; storage = "/dev/nvme1n1"; label = "_empty";      };
```

**True A/B redundancy (слоты на РАЗНЫХ дисках):**
```nix
slot_a = { type = "partition"; storage = "/dev/nvme0n1"; label = "nix-store_1"; };
slot_b = { type = "partition"; storage = "/dev/nvme1n1"; label = "_empty";      };
# → модуль генерирует ДВА sysupdate transfer (InstancesMax=1 каждый),
#   т.к. sysupdate сканирует один диск за раз.
```

**Testing / no-GPT (оба слота — файлы):**
```nix
slot_a = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; label = null; };
slot_b = { type = "regular-file"; storage = "/var/lib/nixtache/ab-slots/"; label = null; };
# provision-сервис НЕ запускается. sysupdate сам создаёт файлы.
```

### Asserts

```nix
assertions = [
  # Типы должны совпадать (sysupdate constraint)
  {
    assertion = slot_a.type == slot_b.type;
    message = ''
      slot_a.type (${slot_a.type}) != slot_b.type (${slot_b.type}).
      systemd-sysupdate requires all instances of a transfer to have
      the same Target.Type. Set both to "partition" or both to "regular-file".
    '';
  }
  # Размер должен совпадать с ab-image (только для абсолютных значений)
  {
    assertion =
      lib.hasSuffix "%" cfg.slotSize ||                       # процент — skip
      config.services.nixtache.ab-image.storeSize == cfg.slotSize;
    message = ''
      ab-image.storeSize (${config.services.nixtache.ab-image.storeSize})
      != ab.partitions.slotSize (${cfg.slotSize}). Must match.
      Note: slotSize as percentage ("10%") skips this check — repart
      (build-time) needs absolute; provision (runtime) resolves % from
      disk size. If using %, ensure storeSize is large enough in practice.
    '';
  }
  # autoInit = true → type = "partition"
  {
    assertion = !cfg.autoInit || slot_a.type == "partition";
    message = "autoInit = true requires type = \"partition\" (can't auto-create files).";
  }
  # type = "partition" → storage должен быть валильным устройством
  {
    assertion = slot_a.type != "partition" || slot_a.storage == "auto" || lib.hasPrefix "/dev/" slot_a.storage;
    message = ''partition type requires storage = "auto" or "/dev/...".'';
  }
  # verify = true → публичный ключ должен быть задан (pubring на target)
  {
    assertion = !cfg.verify || pubring-present;  # publicKeyFile/publicKey (или ab-image's)
    message = ''verify = true, но /etc/systemd/import-pubring.pgp не задан —
      sysupdate отвергнет все staged-манифесты. Задайте partitions.publicKeyFile
      (PUBLIC ключ деплоера; приватный — runner.deploy.ab.signingKeyFile).'';
  }
  # publicKeyFile + publicKey — взаимоисключающие (только ОДИН)
  {
    assertion = !(cfg.publicKeyFile != null && cfg.publicKey != null);
    message = "publicKeyFile и publicKey заданы вместе — выберите один.";
  }
];

---

## Сценарий: как это выглядит в consumer config

```nix
# server/ab-image.nix (consumer)
{ config, ... }:
{
  # ── Image build (что CI собирает) ──────────────────────────────────
  services.nixtache.ab-image = {
    enable = true;
    imageId = "server";
    imageVersion = "42";   # monotonic build id
    storeSize = "2G";
    # ... publicKey, stagingPath, etc.
  };

  # ── Runtime (что на диске таргета) ─────────────────────────────────
  services.nixtache.deploy-target = {
    enable = true;
    ab = {
      enable = true;
      gating = true;   # server = runner-host

      partitions = {
        enable = true;
        slotSize = "2G";       # == ab-image.storeSize (assert)
        autoInit = false;      # слоты созданы nixos-anywhere при установке
        onSizeMismatch = "error";

        slot_a = {
          type = "partition";
          storage = "auto";        # тот же диск, что и root
          label = "nix-store_1";
        };
        slot_b = {
          type = "partition";
          storage = "auto";
          label = "_empty";
        };
      };
    };
  };
}
```

---

## Тесты (что проверить)

### Уже реализованные тесты (зелёные)

| Test | File | Что проверяет |
|---|---|---|
| `ab-image` | `tests/ab-image.nix` | Pure-eval: fixed vs max-disk sizing + Verify=yes/no |
| `ab-vm` | `tests/ab-vm.nix` | Repart image boot в QEMU-KVM: boots v1 + bless + slots + data + polkit + integrity |
| `ab-deploy` | `tests/ab-deploy.nix` | Server-side: runner module nginx + action.yml parser (Q5) |
| `ab-ota-e2e` | `tests/ab-ota-e2e.nix` | **Scenario A**: action.yml → stage → sign → SSH → sysupdate writes to GPT partition on /dev/vdb. GPT раскладывает **ab-provision модуль** (autoInit), transfer Target — из модуля (тест переопределяет только Source) |

### Полный план тестов (сценарии A/B/C + provisioning)

#### Сценарий A — Remote deploy (deployer → target, partition targets)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| A1 ✅ | `ab-ota-e2e` | Полный pipeline через **action.yml** на реальный GPT-диск | 2 VM (deployer+target), action.yml extracted, fake-nix, /dev/vdb GPT через **ab-provision** (autoInit), Type=partition | `nix-store_2` label на /dev/vdb + abtest_2.efi exists |
| A2 | `ab-ota-e2e-squashfs` | Scenario A с **squashFS** + zstd compression | storeFs=squashfs, storeCompression=zstd, level=19 | Same as A1 + verify `mount \| grep squashfs` |
| A3 | `ab-ota-e2e-erofs` | Scenario A с **EROFS** + zstd compression | storeFs=erofs, storeCompression=zstd, level=19 | Same as A1 + verify `mount \| grep erofs` |
| A4 | `ab-ota-e2e-nocompress` | Scenario A **без компрессии** | storeCompression=null | Same as A1 |
| A5 | `ab-ota-e2e-percent-slot` | Scenario A с **процентным** slotSize | storeSize="10%" (resolved at runtime) | Slot size = 10% of /dev/vdb |

#### Сценарий B — Self-deploy (одна машина, file://, local trigger)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| B1 | `ab-deploy-self` | Self-deploy: 1 VM, file:// source, local trigger | 1 VM (selfhost), staging local, file:// transfers | sysupdate reads file://, writes slot B, label change |
| B2 | `ab-deploy-self-gating` | Self-deploy с **gating unit** (mock Forgejo API) | 1 VM, nixtache-ab-apply.service, mock HTTP returning `[]` (idle) | gating-unit polls idle → triggers sysupdate |
| B3 | `ab-deploy-self-busy` | Self-deploy, gating **занят** (mock returns busy runner) | mock HTTP returning `[{busy:true}]` | gating waits → no sysupdate → pending stays |
| B4 | `ab-deploy-self-busy-timeout` | Gating busy → **forceAfterTimeout=true** | mock busy, idleWaitTimeout=10s, forceAfterTimeout=true | After 10s → sysupdate applies anyway |

#### Сценарий C — Signature verification (reject wrong/tampered)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| C1 | `ab-deploy-verify-wrong-key` | Подпись **другим ключом** → sysupdate **отвергает** | 2 VM, Target Verify=yes, pubring from testSignKey, deployer signs with DIFFERENT key | `target.fail("test -f ...")` — update NOT written |
| C2 | `ab-deploy-verify-tampered` | Подпись **правильная**, но .raw **искажён** (1 byte dd) | 2 VM, Target Verify=yes, correct sig + dd corrupt | `target.fail("test -f ...")` — hash mismatch |
| C3 | `ab-deploy-verify-unsigned` | **Нет** SHA256SUMS.gpg при Verify=yes | 2 VM, Target Verify=yes, no signing | `target.fail(...)` — unsigned rejected |
| C4 | `ab-deploy-verify-correct` | Правильная подпись + нетамpered → **принимает** | 2 VM, Target Verify=yes, correct key + correct content | Update written (positive control for C1-C3) |

#### Provisioning — auto-init (sgdisk creates slots)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| P1 | `ab-provision-init` | Пустой диск → autoInit → слоты созданы | 1 VM, /dev/vdb empty, autoInit=true | `sgdisk -p /dev/vdb \| grep nix-store_1` + `_empty`, right size |
| P2 | `ab-provision-idempotent` | Слоты уже есть → provision → **no-op** | Same VM, run provision again | Партиции не изменены |
| P3 | `ab-provision-second-disk` | `slot_a.storage="/dev/vdb"` → слоты на vdb, vda **не тронут** | slot_a/slot_b storage=/dev/vdb | vda partition table unchanged |
| P4 | `ab-provision-different-disks` | slot_a на vdb, slot_b на **vdc** (true A/B) | 2 empty disks, slot_a=/dev/vdb, slot_b=/dev/vdc | Each slot on its own disk |
| P5 | `ab-provision-regular-file` | `type="regular-file"` → provision **skipped**, sysupdate creates files | type=regular-file, slotDir=/var/lib/nixtache/ab-slots/ | No sgdisk, files appear after sysupdate |

#### Provisioning — size mismatch

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| S1 | `ab-provision-size-error` | slotSize изменён → `onSizeMismatch="error"` → **assertion** | slotSize=4G, actual=2G, onSizeMismatch=error | sysupdate disabled, clear message |
| S2 | `ab-provision-size-wipe` | slotSize изменён → `onSizeMismatch="wipe"` → **оба слота стёрты** | slotSize=4G, actual=2G, onSizeMismatch=wipe | Recreated as `nix-store_1` + `_empty` at new size, old data lost |
| S3 | `ab-provision-no-space` | Места на диске нет → **assertion** | autoInit=true, disk full | Clear message (shrink / nixos-anywhere / 2nd disk) |
| S4 | `ab-provision-percent` | slotSize="10%" → резолвится от размера диска | slotSize=10%, /dev/vdb=2GB | Each slot = ~200MB |

#### Provisioning — protection

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| PR1 | `ab-provision-protected` | Wipe требуется для партиции с protectedLabel → **fail** | protectedLabels=["root","data"], wipe zone overlaps "data" | `target.fail(...)` — data partition untouched |

#### Compression

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| K1 | `ab-compression-squashfs-zstd` | squashFS + zstd-19: образ **меньше** чем no-compress | Build two images: zstd vs none | `stat -c%s zstd.raw < none.raw` |
| K2 | `ab-compression-erofs-zstd` | EROFS + zstd-19: образ **меньше** чем no-compress | Build two images: erofs+zstd vs squashfs+none | `stat -c%s erofs.raw < squashfs-none.raw` |
| K3 | `ab-compression-levels` | zstd-1 vs zstd-19: higher level = smaller image | Build 3 images: zstd-1, zstd-9, zstd-19 | Monotonic size decrease |
| K4 | `ab-compression-mount` | squashFS и EROFS **mount** корректно с компрессией | Build + boot appliance with zstd | `mount \| grep /nix/store` shows squashfs/erofs |

#### Runner + A/B compatibility

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| R1 | `ab-runner-store-clone` | После A/B boot: `nix-daemon-storage` клонирует squashFS → /srv/nix | 1 VM, A/B appliance + runner container, store.path="/srv" | `/srv/nix/store/` populated, `nix-daemon-custom` active |
| R2 | `ab-runner-build` | CI build работает на A/B host (через custom daemon) | Same as R1 + `nix build` inside container | Build succeeds, output in `/srv/nix/store/` |
| R3 | `ab-runner-assert-native` | `store.path="/"` + `ab-image.enable=true` → **assertion fires** | store.path="/", ab-image.enable=true | Eval fails with clear message |
| R4 | `ab-runner-reclone-after-swap` | После A/B swap (v1→v2): re-clone добавляет новые пути | Boot v1 → clone → sysupdate → boot v2 → clone | New v2 paths in /srv/nix, old v1 paths still there (additive) |

#### overlay-nix (writable store поверх read-only appliance)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| O1 | `overlay-nix-mount` | OverlayFS mount поднимается: lower=squashFS, upper=root FS | 1 VM, A/B appliance + overlay-nix.enable=true, upperDir=/var/lib/nix-overlay/upper | `mount \| grep overlay \| grep /nix/store`, `nix-daemon-overlay-mount.service` active |
| O2 | `overlay-nix-install` | `nix-env -iA nixpkgs.hello` — пакет ставится в upper layer | Same as O1 + nix-env install | `hello` binary works, store path in `/var/lib/nix-overlay/upper/` |
| O3 | `overlay-nix-shell` | `nix shell nixpkgs#cowsay -c cowsay moo` — работает | Same as O1 | Command exits 0, output contains "moo" |
| O4 | `overlay-nix-gc` | GC удаляет upper-layer пути, **lower не трогает** | Install hello via nix-env → `nix-collect-garbage` | hello gone from upper; system closure (lower) intact |
| O5 | `overlay-nix-persistent` | После reboot persistent upperDir → пакеты **сохраняются** | upperDir=/var/lib/nix-overlay/upper (root FS), install vim, reboot | `vim --version` still works |
| O6 | `overlay-nix-tmpfs` | После reboot tmpfs upperDir → пакеты **теряются** (by design) | upperDir=/tmp/nix-overlay/upper (tmpfs), install vim, reboot | vim gone, overlay remounts empty |
| O7 | `overlay-nix-lower-readonly` | Lower store (squashFS) **не модифицируется** | Before overlay: checksum squashFS. After nix-env install: checksum again | Same checksum — lower untouched |
| O8 | `overlay-nix-path-info` | `nix path-info` видит **оба** слоя (lower + upper) | System closure in lower + hello in upper | Both paths listed |
| O9 | `overlay-nix-ab-swap` | После A/B swap: new lower (v2 store) + same upper (persistent) | Boot v1 + overlay → install tool → sysupdate → boot v2 | Tool still available (upper persistent); new v2 paths visible |

> **Примечание по overlay-nix тестам:** O1-O8 можно писать как `runNixOSTest`
> (boot A/B appliance VM + overlay-nix module). O9 требует двух загрузок
> (v1→sysupdate→v2) — сложнее, но реализуемо через `machine.reboot()`.

#### nixos-anywhere migration (integration)

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| N1 | `ab-nixos-anywhere` | kexec → disko → install → boot on A/B | 1 VM (target), nixos-anywhere via SSH, disko layout with A/B slots | Target boots with squashFS /nix/store, GPT labels present |
| N2 | `ab-nixos-anywhere-hostkeys` | `--copy-host-keys` preserves SSH host keys across reinstall | Same as N1 + --copy-host-keys | SSH host keys same before and after |

> **Примечание по nixos-anywhere тестам (N1-N2):** сложно в runNixOSTest (нужен
> kexec внутри VM + SSH из outer → inner). Можно как multi-stage test: outer VM
> запускает nixos-anywhere на inner VM. Альтернатива: manual integration test
> документированный в runbook, не автоматизированный в CI.

### Приоритеты реализации

| Приоритет | Тесты | Почему |
|---|---|---|
| **P0** (уже есть) | A1 | Базовый pipeline через action.yml на диск |
| **P0** (implement next) | B1, C1, C2 | Self-deploy + verification — ядро A/B |
| **P0** (implement next) | O1, O2, O3 | overlay-nix базовая функциональность — «топовая пушка» |
| **P0** (implement next) | RO1, RO2, RO3 | runner store overlay — заменяет clone, мгновенный boot |
| **P1** | A2-A5, P1-P5, S1-S4 | Provisioning + compression variants |
| **P1** | R1-R3 | Runner compatibility — доказательство что CI не ломается |
| **P1** | O4-O9 | overlay-nix GC + persistent + A/B swap |
| **P1** | RO4-RO7 | runner overlay GC + A/B swap + benchmark |
| **P2** | B2-B4, C3-C4, PR1 | Edge cases (gating, unsigned, protected) |
| **P2** | K1-K4, R4 | Compression benchmarks + re-clone |
| **P3** | N1-N2 | nixos-anywhere integration (may stay manual) |

---

## Артеакты (что реализуется)

- **`modules/deploy-target/ab-provision.nix`** — новый файл:
  `services.nixtache.deploy-target.ab.partitions.*` (disk, slotSize,
  autoInit, onSizeMismatch, protectedLabels, mountPoint, enable).
- **provision script** (bash, встроен в модуль через `pkgs.writeShellScript`):
  detection + creation + size-check + wipe logic (§2).
- **systemd service** `nixtache-ab-provision.service` (oneshot, before
  systemd-sysupdate): запускает provision script при каждой загрузке.
- **Asserts**: `storeSize == slotSize`; disk существует; protectedLabels
  не collide с nix-store_*/\_empty.
- **Тесты**: `tests/ab-provision*.nix` → `checks.x86_64-linux.ab-provision-*`.
- **Migration (scenario A):** не модуль, а **документация** — consumer пишет
  disko-конфиг + запускает `nixos-anywhere --flake .#<cfg> --target-host <host>`.
  nixtache не генерирует disko-конфиг (машинно-специфичный), но документирует
  required layout (ESP + root + slot A `nix-store_1` + свободный `_empty`) и совместимость с
  `nixosModules.ab-image` + `nixosModules.deploy-target`.
- **`modules/ab-image/default.nix`** — `storeFs`, `storeCompression`,
  `storeCompressionLevel` опции (уже реализовано).
- **`modules/overlay-nix/default.nix`** — новый модуль:
  `services.nixtache.overlay-nix.*` (enable, upperDir, workDir). Поднимает
  OverlayFS + nix-daemon с `local-overlay://` store URL поверх read-only
  `/nix/store`. Doc: https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
- **Тесты overlay-nix**: `tests/overlay-nix*.nix` → `checks.x86_64-linux.overlay-nix-*`.

---

## 5. Filesystem model: что где живёт и как сжимается

### A/B swap обновляет ДВА артефакта (не один)

```
sysupdate пишет в один проход:
├── abtest_2.nix-store.raw  →  GPT партиция slot B   (новый read-only store)
└── abtest_2.efi            →  ESP /EFI/Linux/        (новый UKI)
```

**UKI = kernel + initrd + cmdline**, где cmdline содержит
`init=/nix/store/<HASH-V2>/init`. Это хардкоженный путь в **новый** store.
UKI и store-слот — **matched pair**: UKI v2 работает только с store v2.

### Что свопается, что нет

```
/dev/nvme0n1
│
├── p1: ESP (vfat)               → /boot
│   ├── abtest_1+0.efi           ← v1 UKI (tries исчерпаны)
│   └── abtest_2+3.efi           ← v2 UKI (АКТИВНЫЙ) ◄── systemd-boot выбрал
│       └── embeds: init=/nix/store/<HASH-V2>/init
│
├── p2: root (ext4/btrfs)        → /               ← ПЕРСИСТЕНТНЫЙ
│   ├── /var/lib/...             ← сохраняется
│   ├── /home/...                ← сохраняется
│   └── .rw-etc/                 ← overlayfs UPPER для /etc (сохраняется)
│
├── p3: nix-store_1 (read-only)  ← slot A (v1, СТАРЫЙ)
│   └── /nix/store/<HASH-V1>/    ← etc-metadata.erofs (overlayfs LOWER v1)
│
├── p4: nix-store_2 (read-only)  ← slot B (v2, АКТИВНЫЙ)
│   └── /nix/store/<HASH-V2>/    ← etc-metadata.erofs (overlayfs LOWER v2)
│
└── p5: data (ext4)              → /mnt/data      ← ПЕРСИСТЕНТНЫЙ
```

| Что | Где | Меняется при swap? |
|---|---|---|
| `/nix/store` содержимое | p3 ↔ p4 (squashFS/erofs, read-only) | ✅ swap (новые пакеты) |
| UKI (kernel+initrd+cmdline) | p1 ESP `/EFI/Linux/` | ✅ swap (новый `init=`) |
| `/run/current-system` | → symlink в активный store | ✅ указывает на новый toplevel |
| `/etc` overlay LOWER | из активного store | ✅ новые дефолты system closure |
| `/etc` overlay UPPER | p2 root `.rw-etc/` | ❌ **персистентно** (ssh keys, users) |
| `/var`, `/home` | p2 root | ❌ **персистентно** |
| data partitions | p5+ | ❌ **персистентно** |

### /etc — overlayfs между двумя партициями

`system.etc.overlay.enable = true` (из `image-based-appliance` профиля):

```
/etc (overlayfs)
├── LOWER (read-only):  активный store slot (p3 ИЛИ p4)
│   └── etc-metadata.erofs  ← построен mkcomposefs из environment.etc
│                              МЕНЯЕТСЯ при swap (новые дефолты)
│
└── UPPER (read-write): root (p2)
    └── /.rw-etc/upper/       ← ssh_host_*, machine-id, passwd edits
                                 ПЕРСИСТЕНТЕН — не меняется при swap
```

Без overlayfs на `/etc`: потеря локальных правок (если ro из store) ИЛИ stale
конфиги (если персистентный без overlay).

### Compression: build-time only

**Для squashFS и EROFS сжатие — ТОЛЬКО при сборке образа.** Алгоритм и уровень
запекаются в image; при mount указать компрессию нельзя.

```nix
services.nixtache.ab-image = {
  storeFs = "erofs";              # или "squashfs" (default)
  storeCompression = "zstd";      # алгоритм
  storeCompressionLevel = 19;     # уровень (zstd: 1-22, 19=high)
};
```

Модуль передаёт это в repart как `Compression=` / `CompressionLevel=`
(systemd ≥257, одинаковые ключи для squashfs и erofs — repart сам dispatch'ит):

| ФС | Algorithm → mkfs flag | Level → mkfs flag | Доступные алгоритмы |
|---|---|---|---|
| **squashfs** | `-comp <algo>` | `-Xcompression-level <N>` | gzip, lzo, lz4, xz, zstd, lzma |
| **erofs** | `-z<algo>` | `,level=<N>` | lz4, lz4hc, lzma, deflate, libdeflate, zstd |

**Mount-time:** никакой компрессии. `fileSystems."/nix/store".options` контролирует
только `ro`, `nodev`, `nosuid` (по умолчанию от appliance profile).

### btrfs — исключение (не для A/B store)

btrfs можно использовать для **root партиции** (p2), но НЕ для store-слотов (p3/p4).
Причина: btrfs read-write → можно писать → ломает immutability A/B модели. И
compression на btrfs — mount-time (`-o compress=zstd:3`), не build-time.

### Пример: EROFS + zstd 19

```nix
# Consumer config
services.nixtache.ab-image = {
  enable = true;
  imageId = "server";
  imageVersion = "42";
  storeSize = "2G";
  storeFs = "erofs";
  storeCompression = "zstd";
  storeCompressionLevel = 19;    # максимальное сжатие (медленнее build, меньше image)
};
```

Build-time: `mkfs.erofs -zzstd,level=19` → store image сжат zstd-19.
Mount-time: `mount -t erofs /dev/disk/by-partlabel/nix-store_42 /nix/store -o ro,nodev,nosuid`.

---

## 6. Emergency operations на A/B appliance

### Что НЕ работает на A/B (image-based-appliance profile)

| Команда | Работает? | Почему |
|---|---|---|
| `nixos-rebuild switch` | ❌ | `system.switch.enable = false` — нет activation path |
| `nix shell`, `nix run` | ❌ | `nix.enable = false` — нет nix binary, нет daemon |
| `nix-env -i`, `nix profile install` | ❌ | store read-only (squashFS/erofs) |
| `nix copy --to ssh://server` | ❌ | нет daemon на server (некуда писать) |
| `switch-to-configuration` | ❌ | нет (system.switch.enable = false) |

**Это by design:** appliance — immutable image. Единственный способ изменить
систему — пересобрать образ и записать в слот.

### Emergency-deploy скрипт (заменяет update.sh)

Скрипт живёт в **consumer-репозитории** (nixos-configuration). Запускается
**с DESKTOP** (где есть nix) — собирает образ, копирует на server, триггерит
sysupdate. Не требует nix на server.

```bash
#!/usr/bin/env bash
# scripts/emergency-deploy.sh
# Manual A/B deploy when CI is broken.
# Run from DESKTOP (requires nix + ssh access to target).
#
# Usage: ./scripts/emergency-deploy.sh [target-host] [flake-config]
#   ./scripts/emergency-deploy.sh server server-ab
#   ./scripts/emergency-deploy.sh laptop laptop-ab

set -euo pipefail

TARGET="${1:?usage: $0 <target-host> <flake-config>}"
CFG="${2:?usage: $0 <target-host> <flake-config>}"
DEPLOY_USER="nixos-deploy"
STAGE="/var/lib/nixtache/ab-stage/${CFG}"

echo "=== emergency-deploy: $CFG → $TARGET ==="

# ── Phase 1: build sysupdate-package (на desktop, где есть nix) ──────
echo "→ Building sysupdate-package for .$CFG..."
IMG=$(nix build --no-link --print-out-paths .#nixosConfigurations.${CFG}.config.system.build.sysupdate-package)
echo "  built: $IMG"

# ── Phase 2: stage on target (copy via scp, no nix needed on target) ─
echo "→ Staging on $TARGET:$STAGE..."
ssh "$DEPLOY_USER@$TARGET" "mkdir -p $STAGE"
scp "$IMG"/* "$DEPLOY_USER@$TARGET:$STAGE/"

# Regenerate SHA256SUMS (same logic as action.yml _abImage)
ssh "$DEPLOY_USER@$TARGET" "cd $STAGE && sha256sum *.raw *.efi > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS"

# ── Phase 3: sign (if signing key available) ────────────────────────
SIGN_KEY="${EMERGENCY_SIGN_KEY:-}"
if [ -n "$SIGN_KEY" ] && [ -f "$SIGN_KEY" ]; then
  echo "→ Signing SHA256SUMS..."
  GNUPGHOME=$(mktemp -d)
  gpg --batch --import "$SIGN_KEY" 2>/dev/null
  scp "$STAGE/SHA256SUMS" "/tmp/sums.$$"
  gpg --batch --yes --detach-sign -o "/tmp/sums.$$.gpg" "/tmp/sums.$$"
  scp "/tmp/sums.$$.gpg" "$DEPLOY_USER@$TARGET:$STAGE/SHA256SUMS.gpg"
  rm -rf "$GNUPGHOME" "/tmp/sums.$$" "/tmp/sums.$$.gpg"
else
  echo "::warning:: no EMERGENCY_SIGN_KEY — SHA256SUMS left unsigned"
  echo "  (targets MUST have Transfer.Verify=no)"
fi

# ── Phase 4: trigger sysupdate (polkit-authorized deploy user) ──────
echo "→ Triggering systemd-sysupdate on $TARGET..."
ssh "$DEPLOY_USER@$TARGET" "systemctl start systemd-sysupdate.service"

echo ""
echo "✓ Deploy staged + sysupdate triggered."
echo "  Reboot $TARGET to apply: ssh root@$TARGET 'reboot'"
echo "  Rollback: systemd-boot selects previous UKI automatically (boot-counting)."
```

### Emergency-deploy: запуск ПРЯМО на server (без desktop)

Если desktop недоступен (сгорел, в ремонте), но есть **pre-built образ** на USB
или в binary cache:

```bash
# На server, из root shell:
mkdir -p /var/lib/nixtache/ab-stage/server
cp /mnt/usb/sysupdate-package/* /var/lib/nixtache/ab-stage/server/
cd /var/lib/nixtache/ab-stage/server
sha256sum *.raw *.efi > SHA256SUMS
systemctl start systemd-sysupdate.service
reboot
```

Не требует nix — только `cp` + `sha256sum` + `systemctl`. sysupdate сам
тянет из staging (file://), пишет слот, меняет label.

### Emergency rollback (без CI, без desktop)

Boot-counting — автоматический откат:

```bash
# Если новый слот не загрузился (kernel panic, broken service):
# 1. systemd-boot видит tries=0 для v2 → загружает v1 (предыдущий UKI)
# 2. Система грузится из slot A (v1) — предыдущая рабочая версия

# Ручной откат (если система грузится, но нужна другая версия):
# В systemd-boot menu (ESC при загрузке) → выбрать UKI вручную
```

Никаких скриптов. rollback = выбрать другой UKI в boot menu.

### overlay-nix: writable store поверх read-only A/B

> **Решение:** [Nix experimental `local-overlay-store`](https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html)
> — настоящий store type, который **понимает слои** (metadata, GC, validity).
>
> **Дока для будущих агентов:** https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
> Store URL: `local-overlay://?lower-store=...&upper-layer=...`
> Experimental feature: `extra-experimental-features = local-overlay-store`
> Нужен Nix ≥ 2.19 (проверить: `nix --version`; фича появилась в 2.19 —
> `/2.35/` в URL доки вводит в заблуждение).

Не просто `mount -t overlay` поверх `/nix/store` (потеря метаданных, GC ломается),
а полноценный Nix store поверх OverlayFS. Реализованный дизайн
(`modules/overlay-nix/default.nix`): OverlayFS монтируется **overmount'ом прямо
на `/nix/store`** (ro squashFS остаётся смонтирован под ним как lower), а merged
store обслуживает **системный `nix-daemon`**, переприцеленный через
`nix.settings.store` — никакого side-daemon'а и отдельной точки монтирования
вида `/mnt/nix-overlay`:

```
local-overlay://?lower-store=local&upper-layer=/var/lib/nix-overlay/upper&ignore-gc-delete-failure=true&check-mount=false
          │                          │                            │
          │                          │                            └─ upper (read-write)
          │                          │                               user-configured:
          │                          │                               • /var/lib/... (persistent, root FS)
          │                          │                               • /tmp/... (tmpfs, RAM)
          │
          │                          └─ lower (read-only)
          │                             local store → /nix/store (squashFS, active A/B slot)
          │
          └─ merged store — OverlayFS overmount НА /nix/store
             представляется как единый /nix/store
```

`check-mount=false` нужен потому, что overlay — overmount: lowerdir совпадает с
точкой монтирования, и дефолтная проверка `check-mount=true` (сверка с
/proc/mounts) такой расклад отвергает, хотя ядро обрабатывает его корректно.

**Nix-уровневое понимание слоёв:**
- Отдельная SQLite DB в upper layer (metadata для путей, установленных через overlay)
- GC может удалять upper-layer пути (lower — не трогает, `ignore-gc-delete-failure`)
- `nix path-info`, `nix store ls` — работают корректно для обоих слоёв
- В отличие от сырого overlayfs mount: Nix **знает** что lower ro, upper rw

#### Опции модуля

```nix
services.nixtache.overlay-nix = {
  enable = false;
  # Поднимает overlay store на A/B appliance — позволяет nix shell, nix-env,
  # nix build на машине где /nix/store = read-only squashFS/erofs.
  #
  # Doc: https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html

  upperDir = "/var/lib/nix-overlay/upper";
  # Writable layer: где живут дополнительно установленные пути.
  # persistent на root FS (выживает reboot) — recommended.
  # "/tmp/nix-overlay/upper" → tmpfs (RAM, теряется при reboot).
  #
  # User сам решает тип ФС (ext4, btrfs, tmpfs) и размещение
  # (директория, файл через loopback, отдельный раздел) —
  # модуль только создаёт директорию и монтирует overlay.

  workDir = "/var/lib/nix-overlay/work";
  # OverlayFS workdir (должен быть на той же ФС, что upperDir).

  # mergedStore, enableDaemon, experimentalFeatures — module-internal.
};
```

**Что модуль делает при `enable = true`:**

1. Создаёт директории (`tmpfiles.rules`)
2. Монтирует OverlayFS **overmount'ом прямо на `/nix/store`** (mount-only юнит
   `nix-daemon-overlay-mount.service`; idempotent — при уже поднятом overlay
   ничего не делает):
   ```bash
   mount -t overlay overlay \
     -o lowerdir=/nix/store \
     -o upperdir=/var/lib/nix-overlay/upper \
     -o workdir=/var/lib/nix-overlay/work \
     /nix/store
   ```
3. Переприцеливает **системный** `nix-daemon` через `nix.settings.store`:
   ```
   local-overlay://?lower-store=local&upper-layer=/var/lib/nix-overlay/upper&ignore-gc-delete-failure=true&check-mount=false
   ```
4. Включает experimental feature в `nix.conf`:
   ```
   extra-experimental-features = local-overlay-store
   ```

#### Что это даёт

| Операция | Без overlay | С local-overlay-store |
|---|---|---|
| `nix shell nixpkgs#hello` | ❌ store ro | ✅ пишет в upperDir |
| `nix-env -iA nixpkgs.vim` | ❌ нет daemon | ✅ persistent install |
| `nix build` | ❌ store ro | ✓ пишет в upperDir |
| `nix gc` | ❌ ничего не может удалить | ✅ upper-layer пути; lower игнорирует |
| После reboot | — | зависит от upperDir (persistent → сохраняется, tmpfs → теряется) |

#### Отличие от runner's relocated store

| | Runner `/srv/nix` | overlay-nix store |
|---|---|---|
| Где | Внутри контейнера | На host |
| Назначение | CI builds | ad-hoc nix commands (shell, -i, build) |
| Store type | `local` (cloned) | `local-overlay` (layered) |
| Lower | нет (полный clone) | `/nix/store` (squashFS ro) |
| Upper | весь `/srv/nix` | user-specified dir |
| Независимы? | ✅ да — разные stores, разные daemons | ✅ да |

---

## 7. Runner + A/B совместимость

### Проблема

nixtache runner (CI builder) завязан на nix store:
- `nix build`, `nix flake check`, `nix copy` — всё требует writable store
- `nix-daemon-storage.service` клонирует store перед стартом контейнера
- `nix-serve-ng` читает store для binary cache

На A/B appliance: `/nix/store` — read-only squashFS. `nix.enable = false`.

### Почему runner ВЫЖИВАЕТ (Mode B: `store.path = "/srv"`)

```
HOST (A/B appliance, после A/B миграции):
  p2 (root ext4)     → /  ← WRITABLE (persistent)
  p3 (squashFS ro)   → /nix/store ← READ-ONLY (active slot)
  /srv/bincache      ← на p2 (root, WRITABLE)

CONTAINER (runner):
  /nix/store  ← bind из host (squashFS, READ-ONLY)
  /srv        ← bind из host /srv/bincache (root FS, WRITABLE)

  nix-daemon-storage.service:
    nix copy --no-check-sigs --all --to /srv
    └── SOURCE: /nix/store (squashFS ro) — ЧТЕНИЕ OK
    └── DEST:   /srv/nix (root FS rw)   — ЗАПИСЬ OK
    └── Retry loop (5s) если source locked/ro — уже предусмотрено

  nix-daemon-custom.service:
    nix-daemon --daemon (BindPaths=/srv/nix:/nix)
    └── обслуживает WRITABLE clone в /srv/nix

  CI builds:
    nix build → через custom daemon → пишет в /srv/nix ← WRITABLE
```

**Ключевое:** relocated store (`/srv/nix`) живёт на **root партиции** (persistent,
writable), НЕ на squashFS. Клон создаётся при каждом boot — читает из нового
squashFS slot, пишет в root FS. Это **работает с A/B** без изменений.

### Что ЛОМАЕТСЯ

| Проблема | Severity | Когда | Решение |
|---|---|---|---|
| `store.path = "/"` (native mode) — system daemon не может писать в ro squashFS | **FATAL** | Mode A | Assert: A/B host → `store.path != "/"` |
| GC/optimise targetят system daemon (ro) вместо custom (rw) | **Pre-existing** | Оба режима | Spec 0003 (smart-gc) |
| Re-clone при каждом A/B reboot — CI paused до завершения | Minor | Mode B | by design (`Nice=19`, `TimeoutStartSec=1d`) |
| Stale paths в `/srv/nix` от старых slots | Minor | Mode B | Smart-gc (spec 0003) |

### Требуемый assert (новый)

```nix
# modules/runner/store.nix — добавить:
assertions = [{
  assertion = cfg.store.path != "/" || !config.services.nixtache.ab-image.enable;
  message = ''
    services.nixtache.runner.store.path = "/" is incompatible with
    services.nixtache.ab-image.enable = true. The host's /nix/store is
    read-only squashFS on A/B appliances — the container's system daemon
    cannot write CI build outputs. Set store.path to a persistent location
    on the root FS (e.g. "/srv") — the runner clones the store there and
    serves a writable copy via nix-daemon-custom.
  '';
}];
```

> **Почему overlay-nix НЕ отключает этот assert:**
>
> NixOS declarative containers bind-mount **три конкретных пути**, а не весь `/nix`:
> ```
> --bind-ro=/nix/store:/nix/store
> --bind-ro=/nix/var/nix/db:/nix/var/nix/db
> --bind-ro=/nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket
> ```
>
> overlay-nix (separate mount at `/mnt/nix-overlay`) **невидим** контейнеру —
> nspawn резолвит bind sources при старте, overlay смонтирован отдельно.
> Даже если смонтировать overlay **прямо на `/nix/store`** — contents видны,
> но `/nix/var/nix/db` и `/nix/var/nix/daemon-socket` всё ещё указывают на
> squashFS → db не знает о новых путях, socket ведёт к ro daemon.
>
> **Future Option A** (recommended): overlay **заменяет** `nix copy --all`
> clone в runner. `/srv/nix` = OverlayFS mount вместо полной копии. Убирает
> дорогой boot-time clone. Container wiring не меняется.
>
> **Future Option B** (ambitious): overlay на `/nix/store` + overmount
> `/nix/var` writable → system daemon служит overlay через
> `nix.settings.store = local-overlay://...` → контейнер видит writable
> store прозрачно. Нужен initrd для overmount до nix-daemon. После этого
> `path="/"` заработает, assert можно убрать.

### Re-clone behavior при A/B swap

При загрузке в новый slot (после sysupdate + reboot):

```
1. Container boots, squashFS slot B (v2) mounted at /nix/store
2. nix-daemon-storage.service runs:
   nix copy --no-check-sigs --all --to /srv
   └── читает пути из НОВОГО squashFS (v2 store paths)
   └── добавляет их в /srv/nix (старые v1 пути УЖЕ там — additive)
   └── новые пути, которых не было в /srv/nix → копируются
3. nix-daemon-custom запускается с полным store (v1+v2 paths)
4. CI возобновляется
```

Старые пути НЕ удаляются (additive clone). Smart-gc (spec 0003) нужен для
очистки. До реализации smart-gc — stale paths копятся, но не ломают функционал.

---

## 8. Runner store: замена clone на overlay (store.mode = "overlay")

> **Doc:** https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
> **Store URL:** `local-overlay://?root=<store.path>&lower-store=/nix/store&upper-layer=<store.path>/overlay/upper`

### Проблема текущего дизайна (Mode B: clone)

```
Текущий flow (store.path = "/srv"):
  1. Container boots
  2. nix-daemon-storage.service: nix copy --no-check-sigs --all --to /srv
     └── КОПИРУЕТ ВЕСЬ STORE (multi-GB, retry loop, TimeoutStartSec=1d)
     └── CI PAUSED до завершения (минуты)
  3. nix-daemon-custom: обслуживает клон в /srv/nix (local store)
  4. Runner services: BindPaths=["/srv/nix:/nix"]
```

**Проблемы:**
- `nix copy --all` — медленно (multi-GB копия при каждом boot)
- Дублирование store (весь closure ещё раз на диске)
- На A/B reboot — additive copy новых путей из нового slot
- `nix-daemon-storage` — oneshot с `TimeoutStartSec=1d`, CI ждёт

### Новое: OverlayFS заменяет clone (store.mode = "overlay")

```
Новый flow (store.path = "/srv", mode = "overlay"):
  1. Container boots
  2. nix-daemon-overlay-mount.service: mount -t overlay
     └── INSTANT (copy-on-write, не копирует данные)
     └── lower=/nix/store (squashFS ro), upper=/srv/overlay/upper (root FS rw)
     └── merged mount at /srv/nix/store
  3. nix-daemon-custom: обслуживает overlay store (local-overlay://)
     └── Socket: /srv/nix/var/nix/daemon-socket/socket (как раньше)
  4. Runner services: BindPaths=["/srv/nix:/nix"] (как раньше)
```

**Выигрыш:**
- **Нет `nix copy --all`** — overlay mount мгновенный (copy-on-write)
- **Нет дублирования** — upper содержит только НОВЫЕ пути (CI outputs)
- **Boot time** — секунды вместо минут
- **A/B swap** — просто меняется lower (новый slot), upper persistent
- **GC** — local-overlay-store умеет: upper удаляет, lower игнорирует
  (`ignore-gc-delete-failure=true`)

### Что меняется в `modules/runner/store.nix`

```nix
services.nixtache.runner.store = {
  path = "/srv";
  hostBackup = "/srv/bincache";

  mode = "overlay";   # НОВАЯ опция
  # "clone" (default, текущий behavior): nix copy --all → local store
  # "overlay" (новый): OverlayFS mount → local-overlay store
  #                   мгновенный, без копирования, с правильным GC
};
```

#### При `mode = "clone"` (текущий, без изменений):

```nix
# nix-daemon-storage.service (oneshot):
#   nix copy --no-check-sigs --all --to /srv
# nix-daemon-custom.service:
#   nix-daemon --daemon (serves local store at /srv/nix)
```

#### При `mode = "overlay"` (новый):

```nix
# ── 1. OverlayFS mount service (заменяет nix-daemon-storage) ───────
systemd.services.nix-daemon-overlay-mount = {
  description = "Mount OverlayFS for writable nix store overlay";
  wantedBy = [ "multi-user.target" ];
  before = [ "nix-daemon-custom.service" ];
  requires = [ "nix-daemon.service" ];   # system daemon (serves lower)
  path = [ pkgs.util-linux ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = pkgs.writeShellScript "mount-nix-overlay" ''
      # Создать директории для overlay (upper + work на root FS через bind)
      mkdir -p ${cfg.store.path}/nix/var/nix/daemon-socket
      mkdir -p ${cfg.store.path}/overlay/upper
      mkdir -p ${cfg.store.path}/overlay/work
      mkdir -p ${cfg.store.path}/nix/store
      mkdir -p ${cfg.store.path}/nix/var/nix/db

      # OverlayFS: lower=squashFS store (ro), upper=writable (root FS)
      mount -t overlay overlay \
        -o lowerdir=/nix/store \
        -o upperdir=${cfg.store.path}/overlay/upper \
        -o workdir=${cfg.store.path}/overlay/work \
        ${cfg.store.path}/nix/store
    '';
    ExecStop = pkgs.writeShellScript "umount-nix-overlay" ''
      umount ${cfg.store.path}/nix/store || true
    '';
  };
};

# ── 2. Custom daemon: теперь local-overlay-store ───────────────────
systemd.services.nix-daemon-custom = {
  # Те же BindPaths + socket, но daemon использует overlay store URL
  serviceConfig = {
    ExecStart = "${pkgs.nix}/bin/nix-daemon --store "
      + "'local-overlay://?root=${cfg.store.path}"
      + "&lower-store=daemon"           # lower = system daemon (reads squashFS)
      + "&upper-layer=${cfg.store.path}/overlay/upper"
      + "&ignore-gc-delete-failure=true'";  # lower ro — GC can't delete, ignore
    # ... остальные опции те же (SocketUser, BindPaths, etc.)
  };
  # nix.conf inside container: enable experimental feature
  environment.NIX_CONF = ''
    extra-experimental-features = local-overlay-store
  '';
};
```

> **Нет второго daemon'а в смысле «второй STORE»** — custom daemon обслуживает
> ОДИН overlay store (layered), а не отдельную полную копию. Системный daemon
> используется как **lower-store=daemon** (read-only reader squashFS).

### Что НЕ меняется

| Компонент | Изменение? | Почему |
|---|---|---|
| Container `bindMounts` | ❌ | Тот же `/srv` (host) → `/srv` (container) rw bind |
| Per-service `BindPaths` | ❌ | Тот же `["/srv/nix:/nix"]` — runner видит store в `/nix/store` |
| Socket path | ❌ | Тот же `/srv/nix/var/nix/daemon-socket/socket` |
| `instances.nix` / `cache.nix` | ❌ | Тот же `requires=["nix-daemon-custom.service"]` |
| Consumer config | ❌ | `store.path="/srv"` — те же опции |

### A/B swap behavior с overlay

```
Boot в slot B (v2):
1. Container boots, /nix/store = squashFS slot B (v2 paths)
2. nix-daemon-overlay-mount.service:
   mount -t overlay overlay \
     -o lowerdir=/nix/store (v2 squashFS) \
     -o upperdir=/srv/overlay/upper (persistent, root FS) \
     /srv/nix/store
   └── МГНОВЕННО — никаких copy
3. nix-daemon-custom: local-overlay://?lower-store=daemon&upper-layer=/srv/overlay/upper
   └── lower = v2 squashFS paths (через system daemon)
   └── upper = CI build outputs от ПРЕДЫДУЩИХ запусков (persistent)
   └── merged = v2 paths + CI outputs ← INSTANT
4. CI возобновляется НЕМЕДЛЕННО (без ожидания clone)
```

**Stale paths из upper** (CI outputs от старых slots): local-overlay-store
правильно их показывает (они в upper). GC может их удалить. Lower (squashFS)
не меняется — A/B rollback работает.

### Опция модуля

```nix
services.nixtache.runner.store.mode = mkOption {
  type = types.enum [ "clone" "overlay" ];
  default = "clone";
  description = ''
    How the relocated store is populated:

    `clone` (default): `nix copy --all` creates a full writable copy at
    `<store.path>/nix`. Slow (multi-GB), but works on any Nix version.
    The clone is additive across reboots (new paths added, old kept).

    `overlay`: OverlayFS mount combines the read-only lower store
    (`/nix/store`, e.g. squashFS) with a writable upper
    (`<store.path>/overlay/upper`). Instant (no copy), proper GC
    (local-overlay-store type), but requires Nix ≥ 2.19 with the
    `local-overlay-store` experimental feature.

    Doc: https://nix.dev/manual/nix/2.35/store/types/experimental-local-overlay-store.html
  '';
};
```

### Тесты для runner store overlay

| # | Test name | Описание | Setup | Assertions |
|---|---|---|---|---|
| RO1 | `runner-overlay-mount` | OverlayFS mount поднимается вместо clone | 1 VM, runner container, store.mode="overlay" | `mount \| grep overlay \| grep /srv/nix/store`, no `nix-daemon-storage` service |
| RO2 | `runner-overlay-no-clone` | `nix copy --all` НЕ вызывается (boot быстрее) | Same as RO1 + check journal | No "nix copy" in logs, `nix-daemon-overlay-mount` instant |
| RO3 | `runner-overlay-build` | CI build пишет в overlay upper, binary работает | Same as RO1 + `nix build` inside container | Output path in `/srv/overlay/upper/`, binary runs |
| RO4 | `runner-overlay-read-lower` | Существующие пути (из squashFS) видны | Same as RO1 | `nix path-info /nix/store/*` lists lower paths |
| RO5 | `runner-overlay-gc` | GC удаляет upper пути, lower не трогает | Install via build → `nix-collect-garbage` | Upper path gone, lower paths intact |
| RO6 | `runner-overlay-ab-swap` | После A/B swap: new lower (v2) + same upper (persistent) | Boot v1 → build → sysupdate → boot v2 | v2 paths visible (lower), CI output persistent (upper) |
| RO7 | `runner-overlay-boot-time` | Boot с overlay быстрее чем clone (benchmark) | Two VMs: clone vs overlay | overlay boots in seconds, clone takes minutes |

# OTA (A/B image) updates

nixtache's image-based update route: the machine boots from one of two
interchangeable nix-store image **slots**; an update writes the *inactive*
slot and a reboot switches over — no closure copying, no activation on the
running system, instant rollback. Canonical requirements:
[`openspec/specs/ab-ota/spec.md`](../../openspec/specs/ab-ota/spec.md)
(transport/SSH contracts:
[`direct-deploy`](../../openspec/specs/direct-deploy/spec.md),
[`deploy-user`](../../openspec/specs/deploy-user/spec.md)).

Live, rebuild-in-place deploys (`method = "live"`) are the alternative
route — see [`deploy.md`](deploy.md). Every machine picks one route per
deploy-map entry.

## How it works

```
             CI (runner host)                         target appliance
   ┌───────────────────────────────┐        ┌──────────────────────────────┐
   │ nix build sysupdate-package   │        │  ESP:  abtest_1.efi (blessed)│
   │  = nix-store.raw + UKI + sums │ stage  │        abtest_2.efi (new)    │
   │ gpg --detach-sign SHA256SUMS ─┼───────►│  slot A: nix-store_1 (v1)    │
   │ (HTTPS or local dir)          │        │  slot B: nix-store_2 (v2) ←─┼── systemd-sysupdate
   └───────────────────────────────┘        │  root:   persistent /etc,/var│
                                            └──────────────────────────────┘
   reboot → systemd-boot picks the highest version → boot counting blesses
   the boot on boot-complete.target, or rolls back after `ukiTries` fails
```

- **`nixosModules.ab-image`** (build-time, on the target's config): repart
  A/B slots + UKI + `systemd.sysupdate` transfers + boot counting +
  signature verification. Import only on A/B targets — it pulls the
  image-based-appliance profile (`nix.enable = false`).
- **`deploy-target.ab`** (runtime): polkit start-only authorization for the
  sysupdate triggers; on the runner host itself, the idle-gated
  `nixtache-ab-apply` (wait for runners to go idle before self-updating).
- **The apply trigger** (remote action targets and the runner-host
  self-apply alike): the stock units split the duties —
  `systemd-sysupdate.service` runs `update` (fetch + install, never
  reboots), `systemd-sysupdate-reboot.service` runs `reboot` (a purely
  offline check that reboots only when a NEWER version is already
  installed) — so the trigger chains both, update first and with `--wait`
  (the update unit is Type=simple; a plain start returns at fork, long
  before the slot write finished).
- **Runtime versioning**: the version is assigned at deploy time (explicit
  `NIXTACHE_AB_VERSION` or a UTC calendar value), written to the repo's
  `image-version` file before `nix build` (wire it via
  `ab-image.imageVersionFile`) — the same value ends up in the staged
  filenames, the signed manifest and the target's slot label. Re-deploying
  the same version is a no-op on the target.

## First deploy — three routes

### 1. Fresh disk → nixos-anywhere (declarative layout)

Install the appliance onto bare metal with a disko A/B layout (ESP + two
nix-store slots + persistent root) — the reference implementation is
nixtache's own test fixture
[`tests/ab-anywhere-install.nix`](https://code.zinzaguras.ru/nixops/nixtache/src/branch/main/tests/ab-anywhere-install.nix):

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#myhost root@<target-ip>
```

The installed system boots slot A with signature verification on; the next
CI run delivers v2 over OTA.

### 2. Existing machine → provision slots on free space

A machine that already runs (live-deployed or hand-installed) gains A/B by
enabling `deploy-target.ab.partitions` with `autoInit` — the provision
service lays `nix-store_1` + `_empty` GPT slots on free space at boot
(idempotent; refuses safely when free space < 2 × slotSize or when slots
are missing and `autoInit = false`). See
[`ab-ota-migrate-vm`](../technical_details/testing.md) for the covered
migration contract.

```nix
services.nixtache.deploy-target.ab.partitions = {
  enable = true;
  autoInit = true;
  slotSize = "2G";                      # absolute, or "10%" of the disk
  imageId = "myhost";
  source = "https://runner.example.com/ab-stage/myhost/";
  slot_a = { type = "partition"; storage = "/dev/nvme0n1"; };  # labels default
  slot_b = { type = "partition"; storage = "/dev/nvme0n1"; };
  publicKeyFile = ./keys/ab-pubring.pgp;   # → Transfer.Verify=yes
};
```

`onSizeMismatch` governs existing slots of the wrong size: `"error"` stops
updates (sysupdate masked) until you fix `slotSize` and unmask;
`"wipe"` recreates both slots.

### 3. The runner host itself → gated self-update

The machine running the Actions runner cannot reboot mid-job: set
`deploy-target.ab.gating = true` — the staged image is applied only once
all runners report idle (Forgejo API), then `nixtache-ab-apply` triggers
sysupdate + reboot. The auto-update poll is a deliberate no-op there.

## CI wiring

On the runner host, mark the target `method = "ab-image"` in the deploy map
and stage + sign centrally:

```nix
services.nixtache.runner.deploy.targets.myhost = {
  host = "myhost.example.com";
  sshPrivateKey = config.sops.secrets.deploy-myhost.path;
  method = "ab-image";
};
services.nixtache.runner.deploy.ab.signingKeyFile =
  config.sops.secrets.ab-signing-key.path;   # matches the target's pubring
```

The workflow wrapper is the same thin `uses:` as the live path
([deploy.md](deploy.md)); the mode rules (PR → dry, main → switch) and
per-target isolation apply unchanged. Remote targets reboot after the slot
write; the runner host cutover is idle-gated.

## Upgrade, rollback, failure behaviour

| scenario | behaviour |
|---|---|
| healthy update | inactive slot written → reboot → boot counting blesses |
| new boot broken | tries exhaust (default 3) → previous blessed entry boots; the machine stays stable and update-aware (Tier-0). ⚠ from a rolled-back state the running slot is the OLDEST instance — a straight higher-version update targets it (version-driven selection); remove the failed instances (`systemd-sysupdate vacuum`) before updating |
| same version staged | no-op: nothing written, trigger green |
| interrupted update | the active slot is never the write target; the half-written slot never boots; re-install is refused until `systemd-sysupdate vacuum` removes the partial instance, then the next update rewrites the slot |
| unsigned/wrong-key manifest | rejected before any slot is touched (`Transfer.Verify`) |
| tampered payload | checksum validated while streaming into the inactive slot: the unit FAILS mid-install, leaving a partial (never-booted) instance — same `vacuum` recovery as an interruption |
| timer-driven updates | `auto-update` with `method = "ab-image"` (or derived) pulls + reboots per `rebootPolicy` — see [`auto-update.md`](auto-update.md) |

## Overlay synergy (runtime installs)

Appliances can still install packages at runtime via
[`overlay-nix.md`](overlay-nix.md) — including an explicit policy for what
happens to the writable upper layer across these updates
(`upperOnUpdate = "wipe" | "reconcile"`).

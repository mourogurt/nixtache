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
   │  = nix-store.raw + UKI +      │ stage  │        abtest_2.efi (new)    │
   │    lower-db dump + sums       │───────►│  slot A: nix-store_1 (v1)    │
   │ gpg --detach-sign SHA256SUMS  │        │  slot B: nix-store_2 (v2) ←─┼── systemd-sysupdate
   │ (HTTPS or local dir)          │        │  root:   persistent /etc,/var│
   └───────────────────────────────┘        └──────────────────────────────┘
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

## The shipped lower store database

Every image carries its slot closure's *store DB dump* — the validity
records (path, narHash, narSize, references per store path) that make the
read-only lower store a first-class readable nix store. A boot-time loader
(`nixtache-lower-store-db-load.service`) seeds `/nix/var/nix/db` from it:

| moment | what happens |
|---|---|
| image build | the dump is the closure's registered validity records — content-true because the appliance evaluation is content-addressed ([`lower-store-db.md`](../technical_details/lower-store-db.md)) |
| update staging | the dump is part of the signed `sysupdate-package`; the `15-lower-db` transfer installs it on the ESP at `/EFI/nixtache/<imageId>_<version>.lower-db` (old slot's dump vacuumed with its UKI) |
| first boot | the DB is missing → the dump loads, the image version is recorded in a marker |
| slot swap | the new slot's records merge in **additively**; stale old-slot records are left for `nix-store --verify` to report and the overlay reconcile pass to heal |
| after `upperOnUpdate = "wipe"` | the wiped DB re-seeds from the running slot's dump at the next boot |

The image also ships the `nix` CLI — the loader runs on a nix-less
appliance. This is what makes the runner container work on appliance hosts
(both store modes) and runtime installs delta-shaped
([`overlay-nix.md`](overlay-nix.md)); dump/loader internals live in
[`doc/technical_details/lower-store-db.md`](../technical_details/lower-store-db.md).

**Content-addressing requirement**: the appliance target's nixpkgs
evaluation MUST set `nixpkgs.config.contentAddressedByDefault = true` (the
module asserts it with an actionable error), and every machine that
evaluates/builds the image needs the `ca-derivations` experimental feature
in its SYSTEM nix.conf — see the daemon quirk in
[`lower-store-db.md`](../technical_details/lower-store-db.md).

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
are missing and `autoInit = false`). Provisioning creates ONLY the two
nix-store slots — the existing root and ESP stay as they are. The covered
migration contract: [`ab-ota-migrate-vm`](../technical_details/testing.md)
(live-side switch) and `ab-ota-migrate-boot-vm` (first OTA boot on the
migrated disk).

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

#### The migrated-disk contract

Three things on a live-era disk must line up before the first OTA boot, or
the machine flap-rolls-back (boot counting saves it, but the update never
sticks):

1. **Partition identifiers.** The appliance mounts `/` and `/boot` by the
   GPT partlabels `root` and `boot` (the layout route 1 ships). A live-era
   disk usually differs (e.g. FS labels `nixos`/`ESP`). Either relabel:

   ```bash
   sgdisk --change-name=<N>:root --change-name=<M>:boot /dev/<disk>
   ```

   or point the image at the existing devices (the device strings are baked
   into the UKI's initrd fstab, so a config override flows through):

   ```nix
   fileSystems."/".device = lib.mkForce "/dev/disk/by-label/nixos";
   fileSystems."/boot".device = lib.mkForce "/dev/disk/by-label/ESP";
   ```

   If the identifiers don't match, the OTA boot times out waiting for the
   root device, boot counting exhausts the new entry, and the machine boots
   the live generation again — safe, but the update never lands.

2. **Arming the boot selection.** NixOS's systemd-boot installer pins
   `default nixos-*` in `loader/loader.conf` on the ESP (plus `preferred`
   with boot counting). While that pin stands, a staged UKI is never
   selected — staging alone never cuts a migrated machine over. Arm the
   cutover by REMOVING the `default`/`preferred` lines; systemd-boot's
   entry sort (tries-exhausted last, then sort-key — the image's IMAGE_ID
   orders before `nixos`) then picks the newest staged UKI at the next
   reboot. Do NOT replace the pin with a UKI-only glob such as
   `default myhost_*.efi`: the default glob is not boot-assessment-aware
   and would reselect a failed image forever. Once armed, no further ESP
   edits are needed — updates flow by the version sort.

3. **The old update channel.** Set `system.autoUpgrade.enable = false`:
   un-gated autoUpgrade reboots defeat the idle gating (a runner host would
   kill its own CI jobs), and the auto-update module refuses to evaluate
   with both enabled.

Do the flip in two phases: first deploy the config with
`deploy-target.ab.partitions` but WITHOUT `ab-image` (the running system
keeps nix/`switch` and provisions the slots), then import `ab-image` so CI
builds the sysupdate-package. Importing `ab-image` in phase 1 would strip
the live system of nix and `switch-to-configuration` before the first OTA
boot. The deploy-map entry flips to `method = "ab-image"` with phase 2 —
a live deploy against an already-booted appliance fails loudly (no nix, no
switch), so keep the map entry on `"live"` until the cutover is armed.

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

### Expected journal noise: `gpg: WARNING: Using untrusted key!`

Every successful manifest verification logs this warning in the
`systemd-sysupdate.service` journal. It does **not** indicate a missing
trust configuration: sysupdate verifies against the pinned keyring you
ship (`import-pubring.pgp`) and internally invokes `gpg` with a hardcoded
`--trust-model=always` — gpg prints the warning *because* that flag
bypasses its web-of-trust database, unconditionally, on every run. There
is no client-side setting (ownertrust, trustdb, trusted keys) that
silences it, and none is needed: the deployer pubring in the image *is*
the trust anchor. Treat the warning as cosmetic; a real verification
failure instead rejects the manifest (see the table above).

## Overlay synergy (runtime installs)

Appliances can still install packages at runtime via
[`overlay-nix.md`](overlay-nix.md) — including an explicit policy for what
happens to the writable upper layer across these updates
(`upperOnUpdate = "wipe" | "reconcile"`).

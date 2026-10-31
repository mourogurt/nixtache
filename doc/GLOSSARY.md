# nixtache glossary

Canonical vocabulary for the nixtache CI/CD pipeline. One name per concept;
the `_Avoid_` lines list synonyms that must not appear in code, docs or
specs. Terms are concepts — option names and file paths live in the docs
that own them, not here.

## Language

### Deploy pipeline

**Deploy map**:
The runner-side declaration of which machines a runner may deploy to, one
entry per deployable configuration. The deploy action reads it from the job
environment.
_Avoid_: target list, nodes map

**Apply unit**:
The root-owned systemd oneshot on a target that performs an activation
(profile set → switch → health probe → rollback on failure); the only
privileged actor in the pipeline.
_Avoid_: activation service, applier

**Pointer file**:
The handoff file the runner drops on the target naming the staged closure;
the apply unit consumes (deletes) it as it runs. Present ⇒ activation owed.
_Avoid_: trigger file, signal file, flag file

**Critical units**:
The per-target systemd units that must be active for an activation (or
boot) to count as healthy.
_Avoid_: health units, watchdog services

**Tier-0**:
The boot-time rollback tier: a health-check oneshot gates
`boot-complete.target` on the critical units (with boot counting, an
unblessed boot rolls back).
_Avoid_: boot check

**Tier-1**:
The live rollback tier: the apply unit probes the critical units after a
switch and re-activates the previous generation on failure.
_Avoid_: live probe, runtime check

### SSH channel

**SSH gate**:
The forced-command whitelist on the deploy key (an authorized_keys
`restrict,command=` prefix) that passes exactly the deploy protocol's
remote commands and rejects everything else.
_Avoid_: ssh wrapper, command filter, command whitelist (bare "gate" is
ambiguous — say "SSH gate")

**Protocol drift**:
The transition window in which the deploy action and a target's SSH gate
speak different protocol versions; drifted targets are skipped with a
warning, never failing the job.
_Avoid_: version skew, gate mismatch

### Disk-space protection

**Pre-copy disk check**:
The runner-side two-stage refusal (a fast floor check before the build, a
sized estimate check after it) that keeps a space-starved target from
receiving a deployment.
_Avoid_: space probe, pre-flight gate (bare "disk gate" is ambiguous — say
which side)

**Apply-unit disk guard**:
The target-side refusal inside the apply unit: below the free-space
threshold it exits before mutating the system profile, so no rollback is
needed.
_Avoid_: activation guard, ENOSPC guard (bare "disk gate" is ambiguous —
say which side)

### A/B (OTA) updates

**Slot**:
One of the two interchangeable partitions holding a nix-store image; the
active slot boots, the inactive slot receives the next update.
_Avoid_: partition pair, image slot set

**Appliance**:
A machine that boots from A/B slot images instead of being rebuilt in place
(`nix.enable = false` in the image profile; overlay-nix re-enables ad-hoc
nix on top).
_Avoid_: image node, immutable host

**Sysupdate package**:
The update artifact the runner stages and signs: the split nix-store image,
UKI, lower store database dump and SHA256SUMS manifest consumed by
`systemd-sysupdate`.
_Avoid_: update bundle, ota tarball

**Staging**:
Serving the sysupdate package from a location the target can pull from
(local directory or HTTP(S)); staged-image retention is independent of the
binary-cache NAR retention required for overlay repair.
_Avoid_: upload, publish step

**UKI**:
Unified Kernel Image — the kernel+initrd+cmdline EFI executable the boot
loader starts; its filename carries the image version and boot-counting
tries.
_Avoid_: boot image (ambiguous with the store image), efi bundle

**Boot counting**:
Automatic boot assessment: a UKI gets limited tries to reach
`boot-complete.target`; exhausting them rolls the machine back to the
previous blessed entry.
_Avoid_: boot retry, watchdog boot

**Gating**:
The idle-gate on a runner host: by default a self-update waits until all
runners report idle before applying and rebooting; `forceAfterTimeout` can
explicitly override that wait.
_Avoid_: idle lock, maintenance mode

### Self-update

**Flake self-update**:
The CI run that bumps a repository's own `flake.lock` through the reusable
update pipeline — in contrast to the same pipeline bumping a consumer's flake
when the consumer is the caller.
_Avoid_: lock bump, flake auto-update (auto-update is the host channel)

**Host self-update**:
The runner host updating its own system through the auto-update channel
(applying a new A/B slot under idle gating) — a different "self-update" from
the flake self-update.
_Avoid_: system update, machine update

### Overlay store

**Lower layer**:
The read-only store image (squashFS/erofs) mounted at `/nix/store` — the
immutable base of the overlay.
_Avoid_: base store, ro store

**Upper layer**:
The writable directory overlay-nix layers over the lower; runtime installs
land here only when their paths are not already valid in the lower. Its
location and lifecycle policy decide persistence across reboots and updates.
_Avoid_: writable store, delta dir

**Merged store**:
The OverlayFS view at `/nix/store` that combines lower and upper — what
every nix command on the appliance sees.
_Avoid_: combined store, overlay view

**Lower store database**:
The validity records (path, narHash, narSize, deriver, references) shipped
inside the appliance image and seeded into `/nix/var/nix/db` at boot; what
makes the read-only lower layer a first-class readable nix store.
_Avoid_: store dump (that is the carrier file on the ESP), nix db (any
db.sqlite qualifies)

**Store tree**:
The build-time directory that materialises the slot closure (top-level
symlink paths recreated as symlinks) and feeds the image builder as its
single copy source — the unit of faithful store imaging.
_Avoid_: staging tree (collides with Staging above)

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

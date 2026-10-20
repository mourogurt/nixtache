# Design

## Context

`update-flake.yml` currently: guard (env check) → githost → `ssh-setup`
(`creds: update`) → git config → `nix flake update` → validate → rebuild →
push. Two structural constraints shape the fix:

- `ssh-setup` sets a **single global** `git config core.sshCommand` pointing
  at one generated SSH config with one `IdentityFile`. Fetching private inputs
  (flake bundle) and pushing/signing (update bundle) need **both** keys on the
  same host — running ssh-setup twice would overwrite the config.
- The guard runs **before** ssh-setup today, but validating the credential
  requires the SSH config to exist — a circular dependency that forces a step
  reorder.

See proposal.md for motivation; `specs/ci-workflows/spec.md` (delta) for the
requirements.

## Goals / Non-Goals

**Goals:**

- Guard fails fast on a configured-but-broken update credential.
- `nix flake update` fetches private inputs via the flake bundle.
- Fetch errors nix downgrades to warnings still fail the update step.

**Non-Goals:**

- Proving *write* permission before the push (impossible without pushing —
  see Decisions).
- Changing `nix-check.yml` or other workflows (flake-only fetch already works
  there).
- Changing the runner module (`flakeSshCreds`/`updateSshCreds` stay as-is).

## Decisions

### D1: Probe = `git ls-remote` over the push URL, not a real push

The guard runs `git ls-remote ssh://<update-user>@<host>/<repo>` (with the
generated SSH config). This validates authentication and repo visibility —
exactly the class of failure seen in run 907 (`Permission denied
(publickey)`). **Write permission cannot be probed without writing**;
alternatives considered: `ssh -T` (validates auth but not repo access —
weaker), a throwaway ref push (invasive, mutates the consumer repo). Accepted
limitation: a read-only-but-valid key passes the guard and still fails at push
— now with the full log artifact available.

### D2: One SSH config, multiple `IdentityFile` lines

Extend `ssh-setup`'s `creds` input to accept a space-separated list (e.g.
`"flake update"`). The action writes a single `Host` block with one
`IdentityFile` per available bundle — ssh offers them in order, so fetch and
push both work over one `core.sshCommand`. Alternatives considered: two
sequential ssh-setup calls (second overwrites the first's global config —
broken), per-step `GIT_SSH_COMMAND` (fragile; `nix flake update` shells out to
git internally and signing needs the global config anyway).

When `update` is in the list, `key-path`/`config-path` outputs point at the
**update** key (signing identity); otherwise the first listed bundle. `User`
line: `NIXTACHE_UPDATE_GIT_USER` if update is listed, else the flake user,
else the `git-user` input fallback. Missing bundles keep the current
warn-and-skip behavior per bundle (`required: true` escalates to failure).

### D3: Step order — githost, ssh-setup, then guard

New order: checkout → checkout nixtache → **githost → ssh-setup
(`creds: "flake update"`, unconditional)** → **guard** → Setup Git →
sandbox-probe → update → validate → rebuilds → push. ssh-setup runs
unconditionally because it already self-skips with a warning when creds are
absent; the guard then branches: env absent → `enabled=false` (unchanged
no-op), env present + probe OK → `enabled=true`, env present + probe fails →
`exit 1` with `::error::`. All existing `if: steps.guard.outputs.enabled ==
'true'` conditions on later steps are unchanged.

### D4: Fetch-error detection by log grep, not nix flags

Nix has no `--fail-on-fetch-error`; the expired-cache fallback is baked in.
The update step already tees to `artifacts/flake-update.log`; after the
command, `grep -qE '^(error: Failed to fetch|fatal: .*(Permission denied|Could not read from remote))'` fails the step. Grep pattern lives next to
the command that generates the log — one place to maintain.

## Risks / Trade-offs

- [Probe gives false confidence on read-only keys] → documented limitation
  (D1); push failure still produces the uploaded log.
- [Probe adds one SSH round-trip to every enabled run] → `timeout 30` on the
  probe; negligible vs. a rebuild pipeline.
- [`ls-remote` on a shallow/empty repo behaves differently] → probe targets
  `HEAD` only; empty repos still authenticate or fail identically.
- [Grep pattern misses a novel nix error wording] → the log artifact is always
  uploaded, so silent-green detection can be tightened later without workflow
  changes.

## Migration Plan

Pure workflow/action change, pinned via `.nixtache` checkout of `main`:
merging to nixtache `main` rolls it out to all consumers on their next run.
Rollback: pin the caller's nixtache checkout `ref` to the previous commit.

## Open Questions

(none)

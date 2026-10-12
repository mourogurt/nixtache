# Auto-update

`nixosModules.auto-update` provides the unified auto-update channel — the
nixtache replacement for `system.autoUpgrade` (importing both is asserted
against). Requirements (canonical):
[`openspec/specs/direct-deploy/spec.md`](../../openspec/specs/direct-deploy/spec.md);
historical stage spec (mechanics, option tree):
[`doc/archive/specs/direct-deploy/09-auto-update.md`](../archive/specs/direct-deploy/09-auto-update.md).

One module, two mechanisms chosen per system type:

- **flake** (non-OTA): a poll service builds the toplevel from the configured
  flake ref and activates it through the shared `nixtache-apply.service`
  (pointer write + oneshot start) — never raw `nixos-rebuild`. The probe +
  rollback of the deploy pipeline
  ([`deploy.md`](deploy.md)) therefore applies to timer-driven updates
  exactly as to CI deploys.
- **ab-image** (OTA): the poll service triggers `systemd-sysupdate` and owns
  only the trigger + reboot policy; the runner host self-updates through the
  idle-gated `nixtache-ab-apply` unit.

## Contract

```nix
services.nixtache.auto-update = {
  enable = true;
  method = "auto";                     # "auto" (derive) | "flake" | "ab-image"
  flake.url = "git+ssh://forgejo@git.example.com/org/config.git";
  # flake.ref = "release";             # ?ref= for git URLs, /ref for shorthand
  # flake.configuration = "server";    # default: config.networking.hostName
  # flake.sshPrivateKeyFile = <path>;  # for PRIVATE flakes/inputs
  dates = "daily";                     # OnCalendar for the poll timer
  randomizedDelaySec = "1h";           # spread pulls across a fleet
  persistent = true;                   # catch up missed runs at next boot
  rebootPolicy = "if-needed";          # "never" | "if-needed" | "window"
  # rebootWindow = { start = "03:00"; end = "05:00"; };  # for "window"
};
```

- `method = "auto"` (default) derives the mechanism: `"ab-image"` when an
  A/B setup is present (`deploy-target.ab.enable` or `ab-image.enable`),
  otherwise `"flake"`. An explicit value is the escape hatch (e.g. an A/B
  transition period) — the same assertions validate it either way.
- `rebootPolicy`: `never` — never reboot; `if-needed` — reboot when the
  booted kernel differs from the freshly activated one; `window` — defer the
  reboot to a timer inside `rebootWindow`.
- The flake path requires `nixosModules.deploy-target` to be imported (the
  activation goes through `nixtache-apply.service`); the ab path requires a
  resolvable sysupdate source. Violations are eval-time assertions, not
  runtime surprises.
- Recommended role: auto-update is the **fallback channel behind CI deploys**
  — a sparse schedule (daily/weekly) with a large `randomizedDelaySec` is
  typical.

## Migrating from `system.autoUpgrade`

```nix
# BEFORE                          # AFTER
system.autoUpgrade = {            services.nixtache.auto-update = {
  enable = true;                    enable = true;
  flake = "git+ssh://…/config";     flake.url = "git+ssh://…/config";
  dates = "daily";                  dates = "daily";
};                                  rebootPolicy = "if-needed";
                                 };
```

Keeping `system.autoUpgrade` enabled alongside is an eval error. The full
consumer migration walkthrough (including deploy-feature BREAKING changes) is
[`migration.md`](migration.md).
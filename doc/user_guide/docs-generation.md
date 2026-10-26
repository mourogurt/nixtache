# Documenting your flake

nixtache ships a helper so consumers generate documentation for **their own**
`nixosConfigurations` and `devShells`, and a reusable workflow that builds +
uploads it in CI. Requirements background:
[`openspec/specs/docs/spec.md`](../../openspec/specs/docs/spec.md).

## 1. Wire `nixtache.lib.mkDocs` into your `packages`

```nix
# your flake.nix
outputs = { self, nixpkgs, nixtache, ... }: {
  nixosConfigurations = {
    server  = ...;
    desktop = ...;
  };
  devShells.x86_64-linux = {
    default   = ...;
    vrc-shell = ...;
  };

  packages.x86_64-linux = nixtache.lib.mkDocs {
    inherit (nixpkgs) lib;
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    nixosConfigurations = self.nixosConfigurations;        # optional
    devShells = self.devShells.x86_64-linux;               # optional
    # Scope each machine's option reference to the given top-level paths.
    # Omit for the full NixOS option reference (large but searchable).
    optionPrefixes = [ "services.nixtache" "services.myapp" ];
    # Optional: fail the docs build on any option without a `description`
    # (same policy nixtache applies to itself). Default false — missing
    # descriptions are then build-log warnings.
    docStrictMode = true;
  };
};
```

This exposes:

- `packages.<system>.configurationDocs-<machine>` — per-machine option
  reference (CommonMark, via `pkgs.nixosOptionsDoc`, scoped by
  `optionPrefixes`).
- `packages.<system>.devShellDocs` — markdown listing each devShell + its
  `meta.description` (set `meta.description` on your `mkShell` calls).
- `packages.<system>.docs` — the above concatenated; **the artifact CI
  uploads**.
- `packages.<system>.docsHtml` — browsable standalone HTML (pandoc, TOC).
- `packages.<system>.default` — alias of `docs`.

Verify locally: `nix build .#docs` and read the result.

## 2. Add a thin workflow wrapper

```yaml
# your .forgejo/workflows/docs.yml
name: Docs
on:
  push:
    branches: [ main ]
  pull_request:
  workflow_dispatch:

jobs:
  docs:
    uses: nixops/nixtache/.forgejo/workflows/docs.yml@main
    with:
      attributes: "docs"          # flake attr(s) to build; default "docs"
      artifact-name: "docs"       # uploaded artifact name
    secrets: inherit
```

After CI runs, the `docs` artifact contains your generated documentation
(`docs.md` + any per-machine references if you listed multiple
`attributes`). To also build per-machine refs, set
`attributes: "docs configurationDocs-server configurationDocs-desktop"`.

> The reusable workflow runs in the **caller's** context — `actions/checkout`
> checks out your repo, so `nix build .#docs` sees your flake. In the
> Forgejo UI a reusable call renders as two jobs (`docs` 0s caller +
> `docs-1` work); expected. More:
> [`doc/technical_details/workflow-mechanics.md`](../technical_details/workflow-mechanics.md).

### Private flake inputs

If your flake locks private `git+ssh://`/`ssh://` inputs, the docs build
fetches them at generation time. When the locked revision is not already in
the runner's nix store cache and the runner provides no flake SSH
credentials, the workflow fails at input fetch with
`Permission denied (publickey)`. To fetch private inputs, configure the
runner host with `services.nixtache.runner.flakeSshCreds` and make sure the
known-hosts configuration covers **every** SSH host named in your
`flake.lock` (an alias of the git server counts as its own host) — the
workflow derives that host list from the lock file and offers the
credential key on each connection. Flakes with only public inputs need
none of this: a runner without the credentials just warns and builds.
Details: [`doc/technical_details/module-ci-wiring.md`](../technical_details/module-ci-wiring.md);
requirements:
[`openspec/specs/ci-workflows/spec.md`](../../openspec/specs/ci-workflows/spec.md).

## Tips

- **Tag your shells:** `mkShell { meta.description = "VRChat SDK (Python/C++/Qt)"; }`
  — `devShellDocs` surfaces it. Shells without it are listed with a hint.
- **Scope the reference:** `optionPrefixes` keeps each machine's reference
  focused on your namespaces. Without it you get the full ~6000-option NixOS
  reference (useful as an offline manual, large).
- **Custom outputs:** nothing stops you adding your own `packages.<system>.X`
  and pointing `attributes` at it.

# Consumer docs helper.
#
# Exposed by the flake as `nixtache.lib.mkDocs`. Consumers call it to generate
# documentation for THEIR OWN flake outputs (nixosConfigurations + devShells),
# then expose the results as `packages.<system>.<attr>` and let nixtache's
# reusable `docs.yml` workflow build + upload them in CI.
#
# Usage (consumer flake.nix):
#
#   outputs = { self, nixpkgs, nixtache, ... }: {
#     nixosConfigurations = { server = ...; desktop = ...; };
#     devShells.x86_64-linux = { default = ...; vrc-shell = ...; };
#
#   packages.x86_64-linux = nixtache.lib.mkDocs {
#     inherit (nixpkgs) lib;
#     pkgs = nixpkgs.legacyPackages.x86_64-linux;
#     nixosConfigurations = self.nixosConfigurations;      # optional
#     devShells = self.devShells.x86_64-linux;             # optional
#     optionPrefixes = [ "services.nixtache" "services.myapp" ]; # optional
#   };
#   };
#
# Result attrs:
#   configurationDocs-<machine>  — optionsMarkdown per machine (scoped by
#                                  `optionPrefixes` when given, else the full
#                                  NixOS reference for that machine). One
#                                  top-level package attr per machine
#                                  (flattened, not nested: every
#                                  `packages.<system>.*` must be a derivation
#                                  or `nix flake check` rejects it).
#   devShellDocs                 — markdown listing each devShell + its
#                                  `meta.description` (best-effort package
#                                  list when introspectable).
#   docs                         — all of the above concatenated (the default
#                                  artifact the CI workflow uploads).
#   default                      — alias of `docs`.
#
# `optionPrefixes` scopes the per-machine option reference: pass the top-level
# attr paths you actually want documented (e.g. your own module namespaces +
# `services.nixtache.*`). Omit it for the full NixOS option reference (useful
# as a searchable offline manual, large).
#
# `docStrictMode` (default `false`): when `true`, `nixosOptionsDoc` is called
# with `warningsAreErrors = true`, so any option without a `description` FAILS
# the docs build (same policy nixtache applies to its own options). Use it to
# enforce "every mkOption must be documented" in your repo. When `false`
# (default), missing descriptions are downgraded to build-log warnings —
# convenient for flakes that have legitimately undescribed submodule leaves.
{ lib, pkgs, nixosConfigurations ? { }
, devShells ? { }
, optionPrefixes ? [ ]
, docStrictMode ? false
}:
let
  inherit (lib) optionalString;

  # --- per-configuration option docs -------------------------------------
  # `pkgs.nixosOptionsDoc` walks the options tree via
  # `lib.optionAttrSetToDocList`, so passing a PRUNED subtree documents only
  # the surviving options. When `optionPrefixes` is non-empty we prune the
  # tree to options whose dotted location starts with one of the prefixes
  # (string-prefix match, so "services.my-" catches my-forgejo, my-nextcloud,
  # ...; "services.monitoring" catches monitoring.grafana etc.); otherwise we
  # pass the full `options` (~6000 NixOS options — large but searchable).
  keepMatching = prefixes: path: node:
    if lib.isOption node then
      (if lib.any (p: lib.hasPrefix p (lib.concatStringsSep "." path)) prefixes
       then node else null)
    else if lib.isAttrs node then
      let
        filtered = lib.mapAttrs (n: child: keepMatching prefixes (path ++ [ n ]) child) node;
        nonNull = lib.filterAttrs (_: v: v != null) filtered;
      in
      if nonNull == { } then null else nonNull
    else
      null;

  scopedOptions =
    eval:
    if optionPrefixes == [ ] then
      eval.options
    else
      let pruned = keepMatching optionPrefixes [ ] eval.options; in
      if pruned == null then { } else pruned;

  configurationDocs = lib.mapAttrs
    (name: eval:
      (pkgs.nixosOptionsDoc {
        options = scopedOptions eval;
        # docStrictMode (consumer-controlled): when true, missing descriptions
        # fail the build (enforces "every option documented"); when false
        # (default), they're build-log warnings. nixtache's own docs are always
        # strict (see flake.nix ownDocs + AGENTS.md).
        warningsAreErrors = docStrictMode;
      }).optionsCommonMark)
    nixosConfigurations;

  # Combine per-machine option references into one markdown with headings.
  # Each machine's docs file is interpolated directly into the script (the
  # store path is forced + added as a dependency). Empty nixosConfigurations
  # => no per-machine lines => empty output.
  configurationDocsCombined = pkgs.runCommand "configuration-docs.md" { } ''
    : > $out
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (name: doc: ''
        echo "# Configuration: ${name}" >> $out
        echo "" >> $out
        cat ${doc} >> $out
        echo "" >> $out
      '')
      configurationDocs)}
  '';

  # --- devShell docs -----------------------------------------------------
  # Best-effort: list each shell's name + `meta.description` (set via
  # `mkShell { meta.description = "..."; }`). Package introspection from a
  # built shell derivation is unreliable across shell builders, so we surface
  # the description only and direct the reader to `nix flake show` for the
  # authoritative package list.
  devShellDescriptions = lib.mapAttrsToList
    (name: shell:
      "${name}\t${shell.meta.description or "(no meta.description set — add one to your mkShell)"}")
    devShells;

  devShellDocs = pkgs.writeText "devshell-docs.md"
    (optionalString (devShellDescriptions != [ ]) ''
      # DevShells

      | Shell | Description |
      | --- | --- |
      ${lib.concatMapStringsSep "\n" (line:
        "| " + (lib.replaceStrings [ "\t" ] [ " | " ] line) + " |") devShellDescriptions}
    '');

  # --- combined artifact -------------------------------------------------
  hasConfigs = configurationDocs != { };
  hasShells = devShellDescriptions != [ ];

  # One runCommand = one attrs arg + one script arg (runCommand name attrs str).
  # Interpolate store paths directly so they become dependencies AND the script
  # sees concrete paths (avoids relying on derivation-valued env vars).
  docs = pkgs.runCommand "nixtache-consumer-docs.md" { } ''
    {
      echo "# Flake documentation"
      echo ""
      ${optionalString hasConfigs "cat ${configurationDocsCombined}"}
      ${optionalString hasShells "cat ${devShellDocs}"}
      ${optionalString (!hasConfigs && !hasShells) "echo \"_(no nixosConfigurations or devShells passed to mkDocs — nothing to document.)_\""}
    } > $out
  '';

  # Browsable standalone HTML rendered from the combined `docs` markdown via
  # pandoc (self-contained, TOC). Like the NixOS manual page but for the
  # consumer's own configurations + devShells.
  docsHtml = pkgs.runCommand "nixtache-consumer-docs.html"
    {
      nativeBuildInputs = [ pkgs.pandoc ];
    }
    ''
      pandoc ${docs} \
        --standalone --toc --toc-depth=3 \
        --metadata title="Flake documentation" \
        --metadata lang=en \
        -o $out
    '';

  # Flatten per-machine docs (configurationDocs.<machine>) into top-level
  # `configurationDocs-<machine>` package attrs. Every direct child of a
  # flake's `packages.<system>` MUST be a derivation — a nested attrset here
  # fails `nix flake check` with "flake attribute
  # 'packages.<system>.configurationDocs' is not a derivation". The flattened
  # form is also what the reusable docs workflow + generate-docs action build
  # (`.#configurationDocs-<name>`, see .forgejo/workflows/docs.yml).
  configurationDocsFlattened =
    lib.mapAttrs'
      (name: doc: lib.nameValuePair "configurationDocs-${name}" doc)
      configurationDocs;
in
configurationDocsFlattened // {
  inherit devShellDocs docs docsHtml;
  default = docs;
}

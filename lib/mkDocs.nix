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
#   configurationDocs.<machine>  — optionsMarkdown per machine (scoped by
#                                  `optionPrefixes` when given, else the full
#                                  NixOS reference for that machine).
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
{ lib, pkgs, nixosConfigurations ? { }
, devShells ? { }
, optionPrefixes ? [ ]
}:
let
  inherit (lib) optionalString;

  # --- per-configuration option docs -------------------------------------
  # `pkgs.nixosOptionsDoc` walks the options tree via
  # `lib.optionAttrSetToDocList`, so passing a SUBTREE documents only that
  # subtree. When optionPrefixes is non-empty, keep only the matching top-level
  # subtrees and merge them; otherwise pass the full `options`.
  scopedOptions =
    eval:
    if optionPrefixes == [ ] then
      eval.options
    else
      lib.foldl' (acc: prefix:
        let subtree = lib.attrByPath (lib.splitString "." prefix) null eval.options; in
        if subtree == null then acc else acc // { __filtered = true; } // { ${prefix} = subtree; }
      ) { } optionPrefixes;

  configurationDocs = lib.mapAttrs
    (name: eval:
      (pkgs.nixosOptionsDoc {
        options = scopedOptions eval;
      }).optionsCommonMark)
    nixosConfigurations;

  # Combine per-machine docs into one markdown with headings.
  configurationDocsCombined = pkgs.runCommand "configuration-docs.md"
    {
      docs = lib.attrValues configurationDocs;
      names = lib.attrNames configurationDocs;
      passAsFile = [ "names" ];
    }
    ''
      touch $out
      while IFS= read -r n; do
        echo "# Configuration: $n" >> $out
        echo >> $out
      done <"$namesPath"
      # The per-machine files are separate store paths; concatenate in order.
      ${lib.concatStringsSep "\n" (lib.imap0 (i: _: ''
        cat "${lib.elemAt (lib.attrValues configurationDocs) i}" >> $out || true
        echo >> $out
      '') (lib.attrValues configurationDocs))}
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

  docs = pkgs.runCommand "nixtache-consumer-docs.md"
    (lib.optionalAttrs hasConfigs { cfg = configurationDocsCombined; })
    # devShellDocs is a store path either way (writeText always produces one).
    { shell = devShellDocs; }
    ''
      {
        echo "# Flake documentation"
        echo
        ${optionalString hasConfigs "cat \"$cfg\""}
        ${optionalString hasShells "cat \"$shell\""}
        ${optionalString (!hasConfigs && !hasShells) "echo \"_(no nixosConfigurations or devShells passed to mkDocs — nothing to document.)_\""}
      } > $out
    '';

  # Browsable standalone HTML rendered from the combined `docs` markdown via
  # pandoc (self-contained, TOC). Like the NixOS manual page but for the
  # consumer's own configurations + devShells.
  docsHtml = pkgs.runCommand "nixtache-consumer-docs.html"
    {
      nativeBuildInputs = [ pkgs.pandoc ];
      src = docs;
    }
    ''
      pandoc "$src" \
        --standalone --toc --toc-depth=3 \
        --metadata title="Flake documentation" \
        --metadata lang=en \
        -o $out
    '';
in
{
  inherit configurationDocs devShellDocs docs docsHtml;
  default = docs;
}

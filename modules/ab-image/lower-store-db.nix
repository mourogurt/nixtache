# Builds the slot's lower store DB dump: the toplevel closure's REGISTERED
# validity records (`nix-store --load-db`-compatible), straight from
# `pkgs.closureInfo`. Registered narHashes are content-true because the
# appliance evaluation is content-addressed (`ca:fixed:r:` binds the path
# hash to the content hash) — modules/ab-image asserts
# `nixpkgs.config.contentAddressedByDefault`. One derivation per toplevel,
# so image rebuilds with an unchanged closure reuse it. Top-level symlink
# closure paths ship faithfully via the store tree (store-tree.nix) —
# their records describe the symlink itself, which is what the image
# carries.
#
# Used by modules/ab-image (the ESP dump) and by tests/ab-image.nix (the
# pure-eval pin rebuilds this exact derivation to assert identity).
{ pkgs, toplevel }:

let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  # Exposed as passthru.checkScript for the pure-eval pins (mkDerivation
  # consumes the builder text — it is not readable off the result).
  checkScript = ''
    cp ${closureInfo}/registration "$out"
  '';
in
pkgs.runCommand "lower-store-db" { passthru = { inherit checkScript; }; } checkScript

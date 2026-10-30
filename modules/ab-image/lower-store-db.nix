# Builds the slot closure's `nix-store --load-db` dump from closureInfo's
# registration. The content-addressed evaluation asserted by ab-image makes
# those records describe the shipped bytes; the store tree preserves symlink
# paths so their records match the image. One derivation per toplevel is
# reused when the closure is unchanged.
#
# Consumed by the ESP image and by tests/ab-image.nix's identity pin.
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

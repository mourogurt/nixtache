# Builds the slot's lower store DB dump: the toplevel closure's REGISTERED
# validity records (`nix-store --load-db`-compatible), straight from
# `pkgs.closureInfo`. Registered narHashes are content-true because the
# appliance evaluation is content-addressed (`ca:fixed:r:` binds the path
# hash to the content hash) — modules/ab-image asserts
# `nixpkgs.config.contentAddressedByDefault`. One derivation per toplevel,
# so image rebuilds with an unchanged closure reuse it.
#
# Used by modules/ab-image (the ESP dump) and by tests/ab-image.nix (the
# pure-eval pin rebuilds this exact derivation to assert identity).
{ pkgs, toplevel }:

let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  # Exposed as passthru.checkScript for the pure-eval pins (mkDerivation
  # consumes the builder text — it is not readable off the result).
  checkScript = ''
    set -euo pipefail
    # repart resolves top-level symlinks when imaging: a closure path that
    # IS a symlink would ship as its target's content, contradicting the
    # path's record (under `ca:fixed:r:` the path hash IS the content hash,
    # so a rewritten record would fail verification just as hard). Fail the
    # image build listing the offenders — repackage them instead.
    symlinks="$(
      while IFS= read -r p; do
        if [ -L "$p" ]; then printf '%s\n' "$p"; fi
      done < ${closureInfo}/store-paths || true
    )"
    if [ -n "$symlinks" ]; then
      echo 'The appliance closure contains top-level symlink store paths;' >&2
      echo 'the image builder resolves symlinks when imaging, so the shipped' >&2
      echo 'content would contradict the database records of those paths.' >&2
      echo 'Repackage the offenders so their outputs are not symlinks:' >&2
      printf '%s\n' "$symlinks" >&2
      exit 1
    fi
    cp ${closureInfo}/registration "$out"
  '';
in
pkgs.runCommand "lower-store-db" { passthru = { inherit checkScript; }; } checkScript

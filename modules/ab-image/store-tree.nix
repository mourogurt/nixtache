# Stages the slot's store content for the image builder: every toplevel
# closure path materialised directly under $out, with top-level symlink
# paths recreated as symlinks.
#
# Repart resolves every top-level CopyFiles source. Copying closure paths
# individually therefore turns a symlink path into its target's contents and
# contradicts its database record. One tree makes repart preserve the types
# of entries inside it, including symlinks, for input- and content-addressed
# closures alike; the bytes still match closureInfo's registered records.
#
# The closure list is read at build time, avoiding IFD. Reflinks fall back to
# copies; hardlinks are unavailable from the read-only sandbox store.
# Ownership is left to image staging (and cannot be preserved by an
# unprivileged builder), while modes and timestamps are preserved.
{ pkgs, toplevel }:

let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "nix-store-tree"
  {
    # For the pure-eval pins in tests/ab-image.nix, which rebuild this exact
    # derivation and pin identity with the module's tree.
    passthru = { inherit closureInfo; };
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    while IFS= read -r p; do
      base=$(basename "$p")
      if [ -L "$p" ]; then
        # Recreate the symlink verbatim (absolute or relative target
        # string): chains resolve inside the image exactly as on the host.
        ln -s "$(readlink "$p")" "$out/$base"
      else
        cp -a --reflink=auto --no-preserve=ownership "$p" "$out/$base"
      fi
    done < "${closureInfo}/store-paths"
  ''

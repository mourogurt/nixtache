# Stages the slot's store content for the image builder: every toplevel
# closure path materialised directly under $out, with top-level symlink
# paths recreated as symlinks.
#
# Why a store tree (faithful imaging): systemd-repart's CopyFiles opens
# each copy source via chase_and_open, which RESOLVES symlinks — handing it
# one source per closure path (what nixpkgs' `storePaths` option does via
# its amend script) ships a symlink path as its target's content,
# contradicting the path's database record. Such paths are standard
# (nixpkgs' nix.man/nix.doc outputs are symlinks into nix-manual, and the
# appliance ships pkgs.nix), so the image must support them, for
# input-addressed and content-addressed closures alike. Handing repart ONE
# source — this tree — sidesteps the dereference: only the tree itself is
# resolved, while every entry inside is copied type-faithfully (systemd
# copy.c: fd_copy_symlink recreates symlinks). The bytes come straight from
# the build host's store, matching the records closureInfo registered.
#
# The closure list is read at BUILD time from closureInfo's store-paths
# output — no import-from-derivation: this derivation's outPath is known at
# eval time. `--reflink=auto` degrades to a full copy where the filesystem
# lacks reflink support; hardlinks cannot be used at all (the build sandbox
# binds /nix/store read-only and link(2) on a read-only inode is EPERM).
# Ownership is deliberately not preserved: the image builder applies its
# own uid/gid when staging the filesystem, and preserving it would fail for
# the unprivileged build user anyway. Modes and timestamps are preserved.
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

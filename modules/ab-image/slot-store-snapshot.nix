# Builds the slot's store tree and validity database from one immutable
# snapshot. The exported graph supplies path identities and references; Nix
# computes NAR hashes and sizes from the staged bytes in a scratch store.
{ pkgs, toplevel }:

pkgs.stdenvNoCC.mkDerivation {
  name = "slot-store-snapshot";

  __structuredAttrs = true;
  exportReferencesGraph.closure = [ toplevel ];

  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.jq
    pkgs.nix
  ];

  preferLocalBuild = true;

  buildCommand = ''
    set -euo pipefail

    out=''${outputs[out]}
    mkdir -p "$out/root/nix/store"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    jq -r '.closure[].path' "$NIX_ATTRS_JSON_FILE" | LC_ALL=C sort > "$tmp/expected-paths"

    while IFS= read -r path; do
      base=$(basename "$path")
      if [ -L "$path" ]; then
        ln -s "$(readlink "$path")" "$out/root/nix/store/$base"
      else
        cp -a --reflink=auto --no-preserve=ownership "$path" "$out/root/nix/store/$base"
      fi
    done < "$tmp/expected-paths"

    find "$out/root/nix/store" -mindepth 1 -maxdepth 1 -printf '/nix/store/%f\n' \
      | LC_ALL=C sort > "$tmp/staged-paths"
    diff -u "$tmp/expected-paths" "$tmp/staged-paths"

    export NIX_REMOTE="local?root=$out/root&state=$tmp/state"
    export USER=nobody
    jq -r '.closure | map([.path, "", (.references | length)] + .references) | add | map("\(.)\n") | add' \
      < "$NIX_ATTRS_JSON_FILE" | head -n -1 | nix-store --register-validity
    nix-store --dump-db > "$out/lower-db"

    : > "$tmp/dumped-paths"
    while IFS= read -r path; do
      IFS= read -r narHash
      IFS= read -r narSize
      IFS= read -r deriver
      IFS= read -r referenceCount
      printf '%s\n' "$path" >> "$tmp/dumped-paths"
      for ((i = 0; i < referenceCount; i++)); do
        IFS= read -r reference
      done
    done < "$out/lower-db"
    LC_ALL=C sort -o "$tmp/dumped-paths" "$tmp/dumped-paths"
    diff -u "$tmp/expected-paths" "$tmp/dumped-paths"

    nix-store --query --requisites ${toplevel} | LC_ALL=C sort > "$tmp/query-paths"
    diff -u "$tmp/expected-paths" "$tmp/query-paths"

    while IFS= read -r path; do
      nix-store --verify-path "$path"
    done < "$tmp/expected-paths"
  '';
}

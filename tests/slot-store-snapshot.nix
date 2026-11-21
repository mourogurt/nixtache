{ pkgs }:

let
  mkSnapshot = import ../modules/ab-image/slot-store-snapshot.nix;

  regularFixture = pkgs.runCommand "snapshot-regular-fixture" { } ''
    mkdir "$out"
    printf 'source bytes\n' > "$out/data"
  '';
  symlinkFixture = pkgs.runCommand "snapshot-symlink-fixture" { } ''
    ln -s ${regularFixture} "$out"
  '';

  snapshot = mkSnapshot {
    inherit pkgs;
    toplevel = symlinkFixture;
  };

  # Intercept only the fixture's registration command. Production snapshot
  # construction has no mutation hook; this wrapper changes staged bytes
  # before Nix hashes them to prove that source registration is not copied.
  mutatingNix = pkgs.runCommand "snapshot-mutating-nix" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.nix}/bin/nix "$out/bin/nix"
    cat > "$out/bin/nix-store" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    for arg in "$@"; do
      if [ "$arg" = "--register-validity" ]; then
        staged="$out/root/nix/store/$(basename ${regularFixture})"
        chmod u+w "$staged" "$staged/data"
        printf 'staged bytes differ\n' >> "$staged/data"
      fi
    done
    exec ${pkgs.nix}/bin/nix-store "$@"
    EOF
    chmod +x "$out/bin/nix-store"
  '';

  alteredSnapshot = mkSnapshot {
    pkgs = pkgs // { nix = mutatingNix; };
    toplevel = symlinkFixture;
  };

  missingPathFindutils = pkgs.runCommand "snapshot-missing-path-findutils" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/find" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    staged="$out/root/nix/store/$(basename ${regularFixture})"
    chmod -R u+w "$staged"
    rm -rf "$staged"
    exec ${pkgs.findutils}/bin/find "$@"
    EOF
    chmod +x "$out/bin/find"
  '';

  danglingReferenceJq = pkgs.runCommand "snapshot-dangling-reference-jq" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/jq" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    for filter in "$@"; do
      case "$filter" in
        *"map([.path"*)
          input=$(mktemp)
          trap 'rm -f "$input"' EXIT
          cat > "$input"
          ${pkgs.jq}/bin/jq \
            --arg root ${symlinkFixture} \
            --arg dangling /nix/store/00000000000000000000000000000000-dangling-reference \
            '(.closure[] | select(.path == $root).references) += [$dangling]' \
            "$input" | ${pkgs.jq}/bin/jq "$@"
          exit 0
          ;;
      esac
    done
    exec ${pkgs.jq}/bin/jq "$@"
    EOF
    chmod +x "$out/bin/jq"
  '';

  corruptingNix = pkgs.runCommand "snapshot-corrupting-nix" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.nix}/bin/nix "$out/bin/nix"
    cat > "$out/bin/nix-store" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    for arg in "$@"; do
      if [ "$arg" = "--verify-path" ]; then
        staged="$out/root/nix/store/$(basename ${regularFixture})"
        chmod u+w "$staged" "$staged/data"
        printf 'post-registration corruption\n' >> "$staged/data"
      fi
    done
    exec ${pkgs.nix}/bin/nix-store "$@"
    EOF
    chmod +x "$out/bin/nix-store"
  '';

  missingPathCheck = pkgs.testers.testBuildFailure' {
    name = "slot-store-snapshot-missing-path-test";
    drv = mkSnapshot {
      pkgs = pkgs // { findutils = missingPathFindutils; };
      toplevel = symlinkFixture;
    };
    expectedBuilderLogEntries = [ "snapshot-regular-fixture" ];
  };

  danglingReferenceCheck = pkgs.testers.testBuildFailure' {
    name = "slot-store-snapshot-dangling-reference-test";
    drv = mkSnapshot {
      pkgs = pkgs // { jq = danglingReferenceJq; };
      toplevel = symlinkFixture;
    };
    expectedBuilderLogEntries = [ "dangling-reference" ];
  };

  postRegistrationCorruptionCheck = pkgs.testers.testBuildFailure' {
    name = "slot-store-snapshot-post-registration-corruption-test";
    drv = mkSnapshot {
      pkgs = pkgs // { nix = corruptingNix; };
      toplevel = symlinkFixture;
    };
    expectedBuilderLogEntries = [ "was modified" ];
  };

  verifySnapshot = name: snapshot: altered: pkgs.runCommand name
    {
      inherit snapshot;
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gawk
        pkgs.nix
      ];
    }
    ''
      set -euo pipefail
      tmp=$(mktemp -d)
      trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

      cp -a "$snapshot/root" "$tmp/source-root"
      chmod -R u+w "$tmp/source-root"
      sourceUri="local?root=$tmp/source-root&state=$tmp/source-state"
      destinationUri="local?root=$tmp/destination-root&state=$tmp/destination-state"
      export USER=nobody
      export NIX_CONFIG='experimental-features = nix-command'

      export NIX_REMOTE="$sourceUri"
      nix-store --load-db < "$snapshot/lower-db"
      nix-store --verify-path ${regularFixture}
      nix-store --verify-path ${symlinkFixture}

      stagedLink="$tmp/source-root/nix/store/$(basename ${symlinkFixture})"
      [ -L "$stagedLink" ]
      [ "$(readlink "$stagedLink")" = "${regularFixture}" ]

      dumpedHash=$(awk -v path=${regularFixture} '$0 == path { getline; print; exit }' "$snapshot/lower-db")
      sourceHash=$(nix hash path --type sha256 --base16 ${regularFixture})
      if [ "${if altered then "1" else "0"}" = 1 ]; then
        [ "$dumpedHash" != "$sourceHash" ] || {
          echo "staged mutation did not change the emitted NAR hash" >&2
          exit 1
        }
      else
        [ "$dumpedHash" = "$sourceHash" ] || {
          echo "snapshot NAR hash does not describe its staged regular path" >&2
          exit 1
        }
      fi

      nix copy --all --from "$sourceUri" --to "$destinationUri" --no-check-sigs

      export NIX_REMOTE="$destinationUri"
      nix-store --query --requisites ${symlinkFixture} | LC_ALL=C sort > "$tmp/copied-paths"
      printf '%s\n' ${regularFixture} ${symlinkFixture} | LC_ALL=C sort > "$tmp/expected-paths"
      diff -u "$tmp/expected-paths" "$tmp/copied-paths"
      nix-store --verify-path ${regularFixture}
      nix-store --verify-path ${symlinkFixture}

      copiedLink="$tmp/destination-root/nix/store/$(basename ${symlinkFixture})"
      [ -L "$copiedLink" ]
      [ "$(readlink "$copiedLink")" = "${regularFixture}" ]

      mkdir "$out"
      printf 'snapshot registration, closure copy and NAR verification passed\n' > "$out/report"
    '';
  normalCheck = verifySnapshot "slot-store-snapshot-test" snapshot false;
  alteredCheck = verifySnapshot "slot-store-snapshot-altered-test" alteredSnapshot true;
in
pkgs.runCommand "slot-store-snapshot-tests"
  {
    deps = [
      normalCheck
      alteredCheck
      missingPathCheck
      danglingReferenceCheck
      postRegistrationCorruptionCheck
    ];
  }
  ''
    mkdir "$out"
    cat ${normalCheck}/report ${alteredCheck}/report > "$out/report"
    cat >> "$out/report" <<'EOF'
    missing staged path rejected
    dangling reference rejected
    post-registration corruption rejected
    EOF
  ''

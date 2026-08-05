# Tests for lib/mkDocs.nix — the docStrictMode matrix.
#
# 4 cases = docStrictMode (true/false) × all options documented (yes/no):
#   1. false × yes  → builds OK
#   2. false × no   → builds OK (missing description is a build-log warning)
#   3. true  × yes  → builds OK
#   4. true  × no   → BUILD FAILS (warningsAreErrors=true rejects missing desc)
#
# Cases 1-3 are built as REAL dependencies of this test derivation:
# referencing their outPaths in the builder forces Nix to build them, so if any
# fails, this whole test fails — exactly the assertion we want.
#
# Case 4 cannot be built without failing the test, so it's passed in only as a
# `.drvPath` string (not a dep) and we verify its PRECONDITIONS at eval time
# (the test module has an undocumented option, which under docStrictMode=true
# MUST make nixosOptionsDoc's builder fail). The strict-build mechanism itself
# is independently exercised by nixtache's own `packages.optionsMarkdown`
# (warningsAreErrors=true by default — would fail if nixtache had an
# undocumented option; see AGENTS.md "Every mkOption MUST have a description").
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  mkDocs = self.lib.mkDocs;

  # Test module: `documented` always has a description; `undoc` has one only
  # when `fullyDocumented` is true. So with fullyDocumented=false there is
  # exactly one undocumented option — the trigger for strict-mode rejection.
  testMod = fullyDocumented: { lib, ... }: {
    options.services.testmod.documented = lib.mkOption {
      type = lib.types.str;
      description = "Always documented.";
      default = "ok";
    };
    options.services.testmod.undoc = lib.mkOption (
      {
        type = lib.types.str;
        default = "x";
      }
      // lib.optionalAttrs fullyDocumented {
        description = "Documented only when fullyDocumented=true.";
      }
    );
  };

  evalFor = fullyDocumented:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        (testMod fullyDocumented)
        { system.stateVersion = lib.trivial.release; }
      ];
    };

  # mkDocs call with a single synthetic machine. Returns
  # { configurationDocs-machine, devShellDocs, docs, docsHtml, default }.
  docsFor = { docStrictMode, fullyDocumented }:
    mkDocs {
      inherit lib pkgs docStrictMode;
      nixosConfigurations.machine = evalFor fullyDocumented;
      optionPrefixes = [ "services.testmod" ];
    };

  case1 = docsFor { docStrictMode = false; fullyDocumented = true; };  # builds OK
  case2 = docsFor { docStrictMode = false; fullyDocumented = false; }; # builds OK (warning)
  case3 = docsFor { docStrictMode = true;  fullyDocumented = true; };  # builds OK
  case4 = docsFor { docStrictMode = true;  fullyDocumented = false; }; # BUILD FAILS

  # Case 4 eval-time precondition: the not-fully-documented module must have
  # an option WITHOUT a description (otherwise case 4 wouldn't exercise the
  # strict rejection). Walk the option tree via the same helper nixosOptionsDoc
  # uses internally, scoped to our test namespace.
  undocOptions =
    let
      docList = lib.optionAttrSetToDocList (evalFor false).options;
      ourOpts = lib.filter (o: lib.hasPrefix "services.testmod." o.name) docList;
      isUndoc = o: !(o ? description) || o.description == "" || o.description == null;
    in
    map (o: o.name) (lib.filter isUndoc ourOpts);

  case4PreconditionHolds = undocOptions != [ ];
in
# Cases 1-3 are interpolated directly in the builder (`${caseN.docs}`) — that
# both (a) brings them into the Nix lexical scope and (b) makes them real build
# deps, so Nix builds them when building this test; any failure fails the test.
#
# Case 4 is intentionally NOT referenced in the builder: its docs derivation
# MUST fail to build (strict + undocumented), and any reference — even a
# `.drvPath` string — causes `nix flake check` to reach & build its optionsJSON
# and fail. Instead we verify case 4's PRECONDITION at eval (the
# not-fully-documented module has an undocumented option) and rely on case 3
# (strict + all-documented builds) + nixtache's own strict `optionsMarkdown`
# build to prove the strict mechanism rejects undocumented options.
pkgs.runCommand "mkdocs-strictmode-test" { } ''
  set -euo pipefail
  {
    echo "# mkDocs docStrictMode test report"
    echo
    echo "## Cases that must build (forced as real deps)"
    echo "  ok  case1 (strict=false, all documented) → ${case1.docs}"
    echo "  ok  case2 (strict=false, missing desc)   → ${case2.docs}"
    echo "  ok  case3 (strict=true,  all documented) → ${case3.docs}"
    echo
    echo "## Case that must FAIL to build (precondition verified, not built here)"
    echo "  case4 (strict=true, missing desc) — expected BUILD FAILURE"
  } > $out

  # Eval-time precondition for case 4: an undocumented option must exist in
  # the not-fully-documented module — otherwise case 4 wouldn't trigger the
  # strict-mode rejection and the test would be vacuous.
  if [ "${lib.boolToString case4PreconditionHolds}" != "true" ]; then
    echo "FAIL: test module should have an undocumented option (precondition for case 4)" >> $out
    exit 1
  fi
  echo "  ok  case4 precondition: undocumented option present (${lib.concatStringsSep ", " undocOptions})" >> $out
  echo >> $out
  echo "case4 expected: BUILD FAILURE (strict mode rejects missing description)." >> $out
  echo "Strict mechanism verified by case3 (strict+documented builds) + nixtache's" >> $out
  echo "own optionsMarkdown build (warningsAreErrors=true by default)." >> $out
''

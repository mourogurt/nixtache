# ab-deploy-drift — protocol-drift skip contract of the deploy action,
# pinned WITHOUT a VM: the action's composite `run:` text is extracted at
# build time (same single-source extraction as tests/ab-ota-e2e.nix) and run
# against a FAKE environment where the target's SSH gate predates the
# free-space query. The canonical requirement lives in the direct-deploy
# capability ("Protocol-drift target is skipped, job stays green"); this
# suite exercises the ACTION side of it (the gate side is module code,
# covered by the deploy-target VM suites).
#
# Fake boundary: `ssh` and `nix` are wrappers on PATH. The fake OLD gate:
# the probe (`ssh ... true`) passes; the free-space query (any ssh invocation
# carrying `df -B1`) is REJECTED, like a forced-command whitelist that
# predates the query. The rest of the live path is never reached (the
# action skips the target before any build/copy). Fast, no KVM — wired
# into checks.<system>.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  actionYml = builtins.readFile ../.forgejo/actions/deploy-target/action.yml;
  actionYmlFile = pkgs.writeText "deploy-action.yml" actionYml;

  actionRunScript = pkgs.runCommand "deploy-action-from-yml" {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyyaml ])) ];
  } ''
    python3 <<PYEOF
    import yaml
    with open("${actionYmlFile}") as f:
        a = yaml.safe_load(f)
    run = next(s["run"] for s in a["runs"]["steps"] if "run" in s)
    with open("$out", "w") as f:
        f.write("#!/bin/bash\n")
        f.write(run)
    PYEOF
    chmod +x "$out"
  '';

  fakeSsh = pkgs.writeShellScript "ssh" ''
    case "$*" in
      *"df -B1"*)
        echo "Command rejected by nixtache-ssh-gate: not in whitelist" >&2
        exit 1
        ;;
    esac
    exit 0
  '';

  fakeNix = pkgs.writeShellScript "nix" ''
    if [ "$1" = "flake" ] && [ "$2" = "show" ]; then
      echo '{"nixosConfigurations":{"drift-target":{}}}'
      exit 0
    fi
    exec ${pkgs.nix}/bin/nix "$@"
  '';

  # The action parses `nix flake show --json` with jq — the fake bin dir
  # provides both wrappers ahead of the real ones.
  fakeBin = pkgs.runCommand "fake-bin" { } ''
    mkdir -p $out/bin
    ln -s ${fakeSsh} $out/bin/ssh
    ln -s ${fakeNix} $out/bin/nix
    ln -s ${pkgs.jq}/bin/jq $out/bin/jq
  '';

  deployTargets = builtins.toJSON {
    drift-target = {
      method = "live";
      sshUser = "nixos-deploy";
      host = "drift.example";
      sshPort = "22";
      hasKey = true;
      enable = true;
      extraOptions = [ ];
    };
  };

  deployEnvFile = pkgs.writeText "deploy-env" ''
    export GITHUB_EVENT_NAME=push
    export SANDBOX_OK=0
    export NIXTACHE_DEPLOY_TARGETS='${deployTargets}'
    export CREDENTIALS_DIRECTORY=$PWD/creds
  '';

  runner = pkgs.writeShellScript "run-drift-harness" ''
    set -uo pipefail
    work="$1"
    mkdir -p "$work/artifacts" "$work/creds"
    touch "$work/creds/deploy_ssh_drift-target"
    export PATH=${fakeBin}/bin:$PATH
    cd "$work"
    . ${deployEnvFile}
    export GITHUB_REF="refs/heads/main"
    bash ${actionRunScript} > stdout.log 2> stderr.log
    echo "exit=$?" > exitcode
  '';
in
pkgs.runCommand "ab-deploy-drift-test"
{
  deps = [ actionRunScript ];
  # The harness is invoked by store path (bash "$harness" "$WORK") — no PATH
  # dispatch, so the runner cannot be shadowed or mis-resolved.
  harness = runner;
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
}
''
  set -uo pipefail
  report="$(mktemp)"
  FAIL=0
  pass() { echo "  ok    $1"; echo "ok    $1" >> "$report"; }
  fail() { echo "  FAIL  $1"; echo "FAIL  $1" >> "$report"; FAIL=1; }

  echo "=== ab-deploy-drift (action.yml text vs an old SSH gate) ==="
  WORK=$(mktemp -d)
  bash "$harness" "$WORK"

  # Sanity: the extraction is genuine and carries the drift contract.
  grep -q "protocol drift" ${actionRunScript} || fail "action text lost the drift wording"
  grep -q "return 2" ${actionRunScript} || fail "action text lost the drift rc=2 skip"

  # Drift target: skipped with a per-target warning naming the hatch.
  if grep -q "::warning::drift-target: skipped — target drift.example rejected the free-space query (protocol drift)" $WORK/stdout.log; then
    pass "drift target skipped with a per-target warning"
  else
    fail "no per-target drift warning: $(tail -3 $WORK/stdout.log)"
  fi

  # Job stays green: drift alone must not fail it.
  if grep -q "exit=0" $WORK/exitcode; then
    pass "job exit 0 — drift never fails the job"
  else
    fail "job went red on pure drift: $(cat $WORK/exitcode) $(tail -5 $WORK/stderr.log)"
  fi

  # No copy/apply was attempted against the drifted target (skip, not retry).
  if grep -q "nix copy" $WORK/artifacts/deploy_drift-target.log 2>/dev/null; then
    fail "copy attempted for the drifted target"
  else
    pass "no nix copy against the drifted target"
  fi

  cat "$report"
  cp "$report" "$out"
  [ "$FAIL" = "0" ] || exit 1
''

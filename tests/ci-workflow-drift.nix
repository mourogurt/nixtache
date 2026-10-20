# ci-workflow-drift — sandbox-probe ordering contract over the REAL workflow
# YAMLs in .forgejo/workflows/: every job that builds (a composite action
# consuming SANDBOX_OK, or an inline `nix build` / `nix flake check`) must run
# the `sandbox-probe` action strictly earlier, so the flag the build steps
# read reflects the actual runner instead of defaulting to --no-sandbox.
# Parsing the real files at build time means a workflow that gains a build
# step without a probe fails `nix flake check` here, not on a real runner.
# The inline nix-build consumers (vmtests.yml suite step) are additionally
# pinned to actually derive and apply the SANDBOX_OK flag. Fast, no KVM.
{ nixpkgs, system ? "x86_64-linux" }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  workflowsSrc = pkgs.runCommand "nixtache-forgejo-workflows" { } ''
    mkdir -p $out
    cp ${../.forgejo/workflows}/*.yml $out/
  '';
in
pkgs.runCommand "ci-workflow-drift-test"
{
  nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyaml ])) ];
}
  ''
  set -uo pipefail
  report="$(mktemp)"
  python3 - "${workflowsSrc}" "$report" <<'PYEOF'
  import glob, os, re, sys
  import yaml

  src, report_path = sys.argv[1], sys.argv[2]

  # Composite actions that read SANDBOX_OK (exported by sandbox-probe) and
  # fall back to --no-sandbox when it is unset.
  CONSUMING_ACTIONS = {
      "flake-validation",
      "rebuild-configurations",
      "rebuild-devshells",
      "generate-docs",
      "deploy-target",
  }
  # A run step counts as a build step when a real build starts at a command
  # position; plain evaluation (nix flake metadata / update) does not.
  NIX_BUILD_RE = re.compile(r"(^|[\s(|&;])nix (build|flake check)(\s|$)")

  lines = []
  fails = 0

  def ok(msg):
      lines.append("ok    " + msg)
      print("  ok    " + msg)

  def bad(msg):
      global fails
      fails += 1
      lines.append("FAIL  " + msg)
      print("  FAIL  " + msg)

  def action_name(step):
      parts = [p for p in (step.get("uses") or "").split("/") if p]
      return parts[-1] if parts else ""

  def build_reason(step):
      name = action_name(step)
      if name in CONSUMING_ACTIONS:
          return "uses the %s action" % name
      for line in (step.get("run") or "").splitlines():
          if NIX_BUILD_RE.search(line):
              return "runs nix build / nix flake check"
      return None

  for path in sorted(glob.glob(os.path.join(src, "*.yml"))):
      wf_name = os.path.basename(path)
      with open(path) as f:
          wf = yaml.safe_load(f) or {}
      for job_name, job in (wf.get("jobs") or {}).items():
          steps = job.get("steps") or []
          probe_idx = None
          for i, s in enumerate(steps):
              if action_name(s) == "sandbox-probe":
                  probe_idx = i
                  break
          for i, step in enumerate(steps):
              reason = build_reason(step)
              if reason is None:
                  continue
              label = "%s job '%s' step '%s'" % (wf_name, job_name, step.get("name") or "<unnamed>")
              if probe_idx is None:
                  bad("%s %s, but the job never runs sandbox-probe" % (label, reason))
              elif probe_idx >= i:
                  bad("%s %s, but sandbox-probe runs later (step %d >= %d)" % (label, reason, probe_idx + 1, i + 1))
              else:
                  ok("%s %s — probed at step %d" % (label, reason, probe_idx + 1))

  # vmtests.yml builds suites with an INLINE nix build (no composite action):
  # pin that the step derives the flag from SANDBOX_OK and applies it to the
  # build, so a broken-sandbox KVM runner self-heals to --no-sandbox instead
  # of dying on missing namespaces.
  vm_path = os.path.join(src, "vmtests.yml")
  if os.path.exists(vm_path):
      with open(vm_path) as f:
          vm = yaml.safe_load(f) or {}
      suite_steps = [
          s
          for j in (vm.get("jobs") or {}).values()
          for s in (j.get("steps") or [])
          if "vmTests.x86_64-linux" in (s.get("run") or "")
      ]
      if not suite_steps:
          bad("vmtests.yml: no step references vmTests.x86_64-linux (checker stale?)")
      for s in suite_steps:
          run = s["run"]
          name = s.get("name") or "<unnamed>"
          if "SANDBOX_OK" not in run:
              bad("vmtests.yml step '%s': does not read SANDBOX_OK" % name)
          elif not re.search(r"nix build[^\n]*\$SANDBOX_FLAG", run):
              bad("vmtests.yml step '%s': nix build does not apply $SANDBOX_FLAG" % name)
          else:
              ok("vmtests.yml step '%s' derives and applies SANDBOX_FLAG" % name)

  with open(report_path, "w") as f:
      f.write("\n".join(lines) + "\n")
  sys.exit(1 if fails else 0)
  PYEOF
  rc=$?
  cat "$report"
  cp "$report" "$out"
  exit "$rc"
''

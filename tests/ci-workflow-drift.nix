# ci-workflow-drift — sandbox-probe ordering contract over the REAL workflow
# YAMLs in .forgejo/workflows/: every job that builds (a composite action
# consuming SANDBOX_OK, or an inline `nix build` / `nix flake check`) must run
# the `sandbox-probe` action strictly earlier, so the flag the build steps
# read reflects the actual runner instead of defaulting to --no-sandbox.
# Parsing the real files at build time means a workflow that gains a build
# step without a probe fails `nix flake check` here, not on a real runner.
# The inline nix-build consumers (vmtests.yml suite step) are additionally
# pinned to actually derive and apply the SANDBOX_OK flag. docs.yml is
# additionally pinned to its private-input contract: derive the SSH host list
# from the push host + the caller's flake.lock, then run ssh-setup (optional
# flake bundle) before generate-docs, so uncached private inputs fetch while
# public-only callers keep building without credentials. update-flake.yml is
# additionally pinned to its backward-compatible input contract: both
# triggers default to runner=nixos / validation-profile=consumer, the job
# runs on the caller-selected label, the guard rejects an unknown profile
# before update work, and only the two consumer rebuild steps depend on the
# profile (update, flake validation and push stay profile-independent).
# self-update.yml — nixtache's own caller for that pipeline — is pinned to
# its Monday schedule, manual trigger, online-kvm/test preflight and @main
# reusable target. The self profile discovers and builds the full VM inventory
# only with usable /dev/kvm and records a successful skip otherwise. Four
# LFS-enabled workflows defer checkout transfer to the shared lfs-fetch action;
# fake endpoints exercise SSH preference, HTTPS fallback, explicit endpoint
# preservation and redacted total failure. Fast, no KVM.
{ nixpkgs, system ? "x86_64-linux" }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  workflowsSrc = pkgs.runCommand "nixtache-forgejo-workflows" { } ''
    mkdir -p $out
    cp ${../.forgejo/workflows}/*.yml $out/
    cp ${../.forgejo/actions/lfs-fetch/action.yml} $out/lfs-fetch-action.yml
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
  import glob, os, re, shutil, subprocess, sys, tempfile, textwrap
  import yaml

  src, report_path = sys.argv[1], sys.argv[2]
  action_path = os.path.join(src, "lfs-fetch-action.yml")

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

  def load_workflow(name, description):
      path = os.path.join(src, name)
      if not os.path.exists(path):
          bad("%s: missing (%s)" % (name, description))
          return None, {}
      with open(path) as f:
          wf = yaml.safe_load(f) or {}
      # PyYAML resolves the bare `on:` trigger key to the boolean True.
      return wf, wf.get("on") or wf.get(True) or {}

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

  # docs.yml builds the caller flake, so it wires the same private-input
  # credential path as nix-check.yml: derive the SSH host list from the push
  # host (NIXTACHE_GIT_SSH_HOST) plus the caller's flake.lock, then run
  # ssh-setup with the flake bundle only and required left at its default
  # (false) — missing credentials warn and skip so public-only callers keep
  # building. The whole chain must sit after both checkouts (flake.lock and
  # action resolution) and before generate-docs, or the docs build either
  # misses a locked host (Permission denied) or resolves the action against
  # the wrong checkout.
  docs_path = os.path.join(src, "docs.yml")
  if os.path.exists(docs_path):
      with open(docs_path) as f:
          docs = yaml.safe_load(f) or {}
      docs_jobs = [
          (jname, job)
          for jname, job in (docs.get("jobs") or {}).items()
          if any(action_name(s) == "generate-docs" for s in (job.get("steps") or []))
      ]
      if not docs_jobs:
          bad("docs.yml: no job runs generate-docs (checker stale?)")
      for jname, job in docs_jobs:
          steps = job.get("steps") or []
          label = "docs.yml job '%s'" % jname

          def first(pred):
              for i, s in enumerate(steps):
                  if pred(s):
                      return i
              return None

          checkout_idxs = [i for i, s in enumerate(steps) if action_name(s).startswith("checkout@")]
          nixtache_idx = next((i for i in checkout_idxs if (steps[i].get("with") or {}).get("repository")), None)
          caller_idx = next((i for i in checkout_idxs if i != nixtache_idx), None)
          githost_idx = first(lambda s: s.get("id") == "githost")
          ssh_idx = first(lambda s: action_name(s) == "ssh-setup")
          docs_idx = first(lambda s: action_name(s) == "generate-docs")

          if caller_idx is None or nixtache_idx is None:
              bad("%s: expected two checkouts (caller + nixtache)" % label)
          if docs_idx is None:
              bad("%s: no generate-docs step (checker stale?)" % label)

          if githost_idx is None:
              bad("%s: no host derivation step (id: githost)" % label)
          else:
              if caller_idx is None or nixtache_idx is None or githost_idx < max(caller_idx, nixtache_idx):
                  bad("%s: host derivation must run after both checkouts" % label)
              run = steps[githost_idx].get("run") or ""
              if "NIXTACHE_GIT_SSH_HOST" not in run:
                  bad("%s: host derivation ignores the push host (NIXTACHE_GIT_SSH_HOST)" % label)
              elif "flake.lock" not in run or ".nodes[].locked.url" not in run:
                  bad("%s: host derivation does not read the caller's flake.lock" % label)
              else:
                  ok("%s: host derivation = push host + flake.lock SSH hosts" % label)

          if ssh_idx is None:
              bad("%s: no ssh-setup step (private inputs would fail at fetch)" % label)
          else:
              if githost_idx is None or ssh_idx < githost_idx:
                  bad("%s: ssh-setup must run after host derivation" % label)
              elif nixtache_idx is not None and ssh_idx < nixtache_idx:
                  bad("%s: ssh-setup must run after the nixtache checkout (action resolution)" % label)
              elif docs_idx is not None and ssh_idx > docs_idx:
                  bad("%s: ssh-setup must run before generate-docs" % label)
              else:
                  with_ = steps[ssh_idx].get("with") or {}
                  if with_.get("git-host") != "''${{ steps.githost.outputs.hosts }}":
                      bad("%s: ssh-setup does not consume the derived host list" % label)
                  elif with_.get("creds") != "flake":
                      bad("%s: ssh-setup creds must be exactly 'flake' (got %r)" % (label, with_.get("creds")))
                  elif with_.get("required") == "true":
                      bad("%s: ssh-setup must keep credentials optional (required: true breaks public-only callers)" % label)
                  else:
                      ok("%s: ssh-setup (creds: flake, optional) from derived hosts, before generate-docs" % label)

  # update-flake.yml is the shared consumer+self update pipeline. Pin the
  # backward-compatible input contract: both triggers default to the
  # consumer behavior (nixos runner, consumer profile), the job runs on the
  # caller-selected label, the guard rejects an unknown profile before
  # update work, and only the two consumer rebuild steps depend on the
  # profile — update, flake validation and push stay profile-independent,
  # so existing consumer wrappers keep working unchanged.
  update, update_triggers = load_workflow("update-flake.yml", "reusable update pipeline")
  if update is not None:
      for trig_name in ("workflow_call", "workflow_dispatch"):
          trig = update_triggers.get(trig_name) or {}
          inputs = trig.get("inputs") or {}
          runner_default = (inputs.get("runner") or {}).get("default")
          profile_default = (inputs.get("validation-profile") or {}).get("default")
          if runner_default != "nixos":
              bad("update-flake.yml %s: runner default must be 'nixos' (got %r)" % (trig_name, runner_default))
          elif profile_default != "consumer":
              bad("update-flake.yml %s: validation-profile default must be 'consumer' (got %r)" % (trig_name, profile_default))
          else:
              ok("update-flake.yml %s defaults: runner=nixos, validation-profile=consumer" % trig_name)
      update_job = (update.get("jobs") or {}).get("update-flake")
      if update_job is None:
          bad("update-flake.yml: no 'update-flake' job (checker stale?)")
      else:
          runs_on = update_job.get("runs-on")
          if runs_on != "''${{ inputs.runner }}":
              bad("update-flake.yml: runs-on must be ''${{ inputs.runner }} (got %r)" % (runs_on,))
          else:
              ok("update-flake.yml runs on the caller-selected label")
          steps = update_job.get("steps") or []
          by_name = {s.get("name"): s for s in steps if s.get("name")}
          guard = by_name.get("Guard — update-flake enabled?")
          if guard is None:
              bad("update-flake.yml: no guard step (checker stale?)")
          else:
              case = re.search(r"case\b(.*?)\nesac", guard.get("run") or "", re.S)
              if case is None:
                  bad("update-flake.yml guard: no case/esac validation of validation-profile")
              elif "consumer|nixtache-self" not in case.group(1) or "exit 1" not in case.group(1):
                  bad("update-flake.yml guard: profile validation must accept consumer|nixtache-self and fail on anything else")
              else:
                  ok("update-flake.yml guard validates validation-profile (consumer|nixtache-self only)")
          rebuild_steps = ["Rebuilding All NixOS Configurations", "Rebuilding All Nix DevShells"]
          for name in rebuild_steps:
              step = by_name.get(name)
              if_ = (step.get("if") or "") if step else ""
              if step is None:
                  bad("update-flake.yml: missing step '%s' (checker stale?)" % name)
              elif "steps.guard.outputs.enabled == 'true'" not in if_:
                  bad("update-flake.yml step '%s': must keep the guard condition (got if: %r)" % (name, if_))
              elif "inputs.validation-profile == 'consumer'" not in if_:
                  bad("update-flake.yml step '%s': must be consumer-profile-only (got if: %r)" % (name, if_))
              else:
                  ok("update-flake.yml step '%s' is consumer-profile-only" % name)
          vm_step_name = "Validate VM suites (nixtache-self)"
          for name, step in by_name.items():
              if name in rebuild_steps or name in ("Guard — update-flake enabled?", vm_step_name):
                  continue
              if "validation-profile" in (step.get("if") or ""):
                  bad("update-flake.yml step '%s': must stay profile-independent (got if: %r)" % (name, step.get("if")))
          ok("update-flake.yml shared steps (update, validation, push, artifacts) stay profile-independent")

          vm_step = by_name.get(vm_step_name)
          if vm_step is None:
              bad("update-flake.yml: missing self-only VM validation step")
          else:
              vm_if = vm_step.get("if") or ""
              vm_run = vm_step.get("run") or ""
              if "steps.guard.outputs.enabled == 'true'" not in vm_if or "inputs.validation-profile == 'nixtache-self'" not in vm_if:
                  bad("update-flake.yml VM step: must be guarded and nixtache-self-only (got if: %r)" % vm_if)
              else:
                  ok("update-flake.yml VM step is self-only and never runs for consumer updates")
              if "nix eval --json --apply builtins.attrNames .#vmTests.x86_64-linux" not in vm_run:
                  bad("update-flake.yml VM step: does not discover the full vmTests.x86_64-linux attribute inventory")
              elif 'jq -r' not in vm_run or "xargs -r -n 1 -P 3" not in vm_run:
                  bad("update-flake.yml VM step: inventory must drive bounded per-suite builds")
              elif '.#vmTests.x86_64-linux.$suite' not in vm_run or "artifacts/vm-tests/$suite/full.log" not in vm_run:
                  bad("update-flake.yml VM step: missing per-suite targets or retained full logs")
              elif 'return "$rc"' not in vm_run:
                  bad("update-flake.yml VM step: suite failure status is not propagated")
              else:
                  ok("update-flake.yml VM step discovers and builds the full inventory with per-suite logs")
              skip_pos = vm_run.find("skipping the full VM inventory")
              eval_pos = vm_run.find("nix eval")
              if skip_pos < 0 or eval_pos < 0 or skip_pos > eval_pos:
                  bad("update-flake.yml VM step: unavailable /dev/kvm must skip before inventory discovery")
              elif "[ ! -c /dev/kvm ]" not in vm_run or "[ ! -r /dev/kvm ]" not in vm_run or "[ ! -w /dev/kvm ]" not in vm_run:
                  bad("update-flake.yml VM step: must require a readable/writable /dev/kvm character device")
              elif "artifacts/vm-tests/skipped.log" not in vm_run or "exit 0" not in vm_run[:eval_pos]:
                  bad("update-flake.yml VM step: unavailable KVM must record a skip and exit successfully")
              else:
                  ok("update-flake.yml VM step records a successful skip before discovery when KVM is unavailable")
              step_names = [s.get("name") for s in steps]
              ordered_names = ["Update Flakes Inputs", "Validate Nix Configuration", vm_step_name, "Push Changes"]
              try:
                  positions = [step_names.index(name) for name in ordered_names]
              except ValueError:
                  bad("update-flake.yml: update → flake validation → VM tests → push ordering cannot be checked")
              else:
                  if positions != sorted(positions):
                      bad("update-flake.yml: expected update → flake validation → VM tests → push ordering")
                  else:
                      ok("update-flake.yml orders update → flake validation → VM tests/skip → push")

  # self-update.yml is nixtache's own caller for the shared pipeline: pin
  # the Monday schedule, the manual entry point, the @main reusable target
  # and the self inputs, so schedule or input drift cannot silently change
  # when/where nixtache updates its own lock file.
  self_wf, self_triggers = load_workflow("self-update.yml", "nixtache self-update caller")
  if self_wf is not None:
      crons = [e.get("cron") for e in (self_triggers.get("schedule") or [])]
      if "15 4 * * 1" not in crons:
          bad("self-update.yml: weekly cron must be '15 4 * * 1' (got %r)" % (crons,))
      else:
          ok("self-update.yml weekly cron is 15 4 * * 1 (Monday 04:15 UTC)")
      if "workflow_dispatch" not in self_triggers:
          bad("self-update.yml: manual workflow_dispatch trigger missing")
      else:
          ok("self-update.yml has a manual workflow_dispatch trigger")
      self_jobs = self_wf.get("jobs") or {}
      if set(self_jobs) != {"select-runner", "probe-runner", "update-flake"}:
          bad("self-update.yml: expected select-runner + probe-runner + update-flake jobs (got %r)" % list(self_jobs))
      else:
          select = self_jobs["select-runner"]
          if select.get("runs-on") != "test":
              bad("self-update.yml preflight: must run on test (got %r)" % (select.get("runs-on"),))
          elif (select.get("outputs") or {}).get("runner") != "''${{ steps.select.outputs.runner }}":
              bad("self-update.yml preflight: runner output is not wired from steps.select")
          elif self_wf.get("enable-openid-connect") is not True:
              bad("self-update.yml: must enable OIDC for Authorized Integrations")
          elif "permissions" in select:
              bad("self-update.yml preflight: unsupported Forgejo permissions field must not be present")
          else:
              ok("self-update.yml preflight runs on test with OIDC and exports its runner selection")
          select_steps = select.get("steps") or []
          select_run = "\n".join(s.get("run") or "" for s in select_steps)
          select_env = {k: v for s in select_steps for k, v in (s.get("env") or {}).items()}
          if select_env.get("RUNNER_DISCOVERY_AUDIENCE") != "''${{ vars.NIXTACHE_RUNNER_DISCOVERY_AUDIENCE }}":
              bad("self-update.yml preflight: audience must come from the repository variable")
          elif "/repos/$GITHUB_REPOSITORY/actions/runners" not in select_run or "Authorization: Bearer $jwt" not in select_run:
              bad("self-update.yml preflight: does not query the runners API with the OIDC JWT")
          elif "ACTIONS_ID_TOKEN_REQUEST_URL&audience=$RUNNER_DISCOVERY_AUDIENCE" not in select_run or "NIXTACHE_RUNNER_DISCOVERY_AUDIENCE" not in select_run:
              bad("self-update.yml preflight: does not obtain a JWT for the configured Authorized Integration audience")
          elif "runner=test" not in select_run or "runner=kvm" not in select_run or '"active"' not in select_run or '"idle"' not in select_run or ".labels" not in select_run:
              bad("self-update.yml preflight: must select active/idle kvm and retain test fallback")
          elif 'echo "runner=$runner" >> "$GITHUB_OUTPUT"' not in select_run:
              bad("self-update.yml preflight: selected runner is not exported")
          else:
              ok("self-update.yml preflight discovers online kvm via the API and falls back to test")

          probe = self_jobs["probe-runner"]
          if probe.get("needs") != "select-runner" or probe.get("runs-on") != "''${{ needs.select-runner.outputs.runner }}":
              bad("self-update.yml capability probe: must run on the discovery-selected candidate")
          elif (probe.get("outputs") or {}).get("runner") != "''${{ steps.probe.outputs.runner }}":
              bad("self-update.yml capability probe: runner output is not wired from steps.probe")
          else:
              probe_run = "\n".join(s.get("run") or "" for s in (probe.get("steps") or []))
              if "[ -c /dev/kvm ]" not in probe_run or "[ -r /dev/kvm ]" not in probe_run or "[ -w /dev/kvm ]" not in probe_run:
                  bad("self-update.yml capability probe: must check for a usable /dev/kvm")
              elif 'candidate="''${{ needs.select-runner.outputs.runner }}"' not in probe_run or "runner=test" not in probe_run or "runner=kvm" not in probe_run:
                  bad("self-update.yml capability probe: must choose kvm only for a capable candidate and test otherwise")
              else:
                  ok("self-update.yml capability probe switches device-less KVM candidates to test")

          job = self_jobs["update-flake"]
          if job.get("uses") != "nixops/nixtache/.forgejo/workflows/update-flake.yml@main":
              bad("self-update.yml: must call nixops/nixtache/.forgejo/workflows/update-flake.yml@main (got %r)" % (job.get("uses"),))
          elif job.get("needs") != "probe-runner":
              bad("self-update.yml: update call must need the KVM capability probe")
          else:
              ok("self-update.yml calls the shared pipeline at @main after preflight")
          with_ = job.get("with") or {}
          if with_.get("runner") != "''${{ needs.probe-runner.outputs.runner }}":
              bad("self-update.yml: must forward the preflight runner selection (got %r)" % (with_.get("runner"),))
          elif with_.get("validation-profile") != "nixtache-self":
              bad("self-update.yml: must select the nixtache-self profile (got %r)" % (with_.get("validation-profile"),))
          else:
              ok("self-update.yml self inputs: dynamic kvm/test runner, nixtache-self profile")
          if job.get("secrets") != "inherit":
              bad("self-update.yml: must pass secrets: inherit (the pipeline reads the runner's credential secrets)")
          else:
              ok("self-update.yml forwards secrets: inherit")

  # Every LFS-enabled reusable workflow defers checkout transfer until the
  # shared action has run after SSH setup and before the first build/update.
  lfs_workflows = {
      "nix-check.yml": "Validate Nix Configuration",
      "deploy.yml": "Deploy to targets",
      "docs.yml": "Generate documentation",
      "update-flake.yml": "Update Flakes Inputs",
  }
  with open(action_path) as f:
      lfs_action = yaml.safe_load(f) or {}
  lfs_action_run = "\n".join(
      s.get("run") or "" for s in (lfs_action.get("runs") or {}).get("steps") or []
  )
  for wf_name, work_name in lfs_workflows.items():
      wf, _ = load_workflow(wf_name, "LFS-enabled reusable workflow")
      if wf is None:
          continue
      for jname, job in (wf.get("jobs") or {}).items():
          steps = job.get("steps") or []
          label = "%s job '%s'" % (wf_name, jname)
          caller = next((
              s for s in steps
              if action_name(s).startswith("checkout@")
              and not (s.get("with") or {}).get("repository")
          ), None)
          if caller is None:
              bad("%s: no caller checkout (checker stale?)" % label)
          elif (caller.get("with") or {}).get("lfs") is not False:
              bad("%s: caller checkout must set lfs: false" % label)
          else:
              ok("%s: caller checkout defers LFS transfer" % label)

          names = [s.get("name") for s in steps]
          ssh_idx = next((i for i, s in enumerate(steps) if action_name(s) == "ssh-setup"), None)
          lfs_idx = next((i for i, s in enumerate(steps) if action_name(s) == "lfs-fetch"), None)
          work_idx = next((i for i, s in enumerate(steps) if s.get("name") == work_name), None)
          if ssh_idx is None or lfs_idx is None or work_idx is None:
              bad("%s: expected ssh-setup, lfs-fetch and '%s' steps" % (label, work_name))
          elif not ssh_idx < lfs_idx < work_idx:
              bad("%s: expected ssh-setup < lfs-fetch < %s ordering" % (label, work_name))
          else:
              ok("%s: LFS transport setup follows SSH and precedes build/update work" % label)

          if wf_name == "update-flake.yml":
              push_idx = next((i for i, s in enumerate(steps) if s.get("name") == "Push Changes"), None)
              if push_idx is None or lfs_idx is None or lfs_idx >= push_idx:
                  bad("%s: lfs-fetch must run before Push Changes" % label)
              elif "git config --local lfs.url" not in lfs_action_run or re.search(r"git config[^\n]*--unset[^\n]*lfs\.url", lfs_action_run):
                  bad("lfs-fetch: selected endpoint is not retained in local config for the update push")
              else:
                  ok("update-flake.yml: selected LFS endpoint remains local and effective through Push Changes")

  # Execute the real composite run script against fake git endpoints. The fake
  # emits a credential marker on every pull; the action must capture rather
  # than expose it, including on the no-working-transport path.
  fake_git = textwrap.dedent(r"""#!/bin/bash
      set -u
      config_value() {
        grep -E "^$1 " "$FAKE_STATE/config" 2>/dev/null | tail -n 1 | cut -d' ' -f2- || true
      }
      if [ "$1" = "lfs" ] && [ "''${2:-}" = "version" ]; then
        exit 0
      fi
      if [ "$1" = "config" ] && [ "''${2:-}" = "--get-regexp" ]; then
        if [ "$FAKE_MODE" = "explicit" ]; then
          echo "lfs.url https://explicit.invalid/repo.git/info/lfs"
          exit 0
        fi
        exit 1
      fi
      if [ "$1" = "config" ] && [ "''${2:-}" = "--local" ]; then
        printf '%s %s\n' "$3" "$4" >> "$FAKE_STATE/config"
        printf '%s=%s\n' "$3" "$4" >> "$FAKE_STATE/sets"
        exit 0
      fi
      if [ "$1" = "remote" ] && [ "''${2:-}" = "get-url" ]; then
        echo "https://secret-token@forgejo.invalid/nixops/nixtache.git"
        exit 0
      fi
      if [ "$1" = "lfs" ] && [ "''${2:-}" = "pull" ]; then
        url=$(config_value lfs.url)
        transfer=$(config_value lfs.sshtransfer)
        printf '%s\t%s\n' "$url" "$transfer" >> "$FAKE_STATE/pulls"
        echo "fake endpoint received secret-token" >&2
        case "$FAKE_MODE" in
          ssh)
            if [ "$transfer" = "always" ]; then
              case "$url" in ssh://*) exit 0 ;; esac
            fi
            ;;
          https)
            if [ "$transfer" = "never" ]; then
              case "$url" in https://*) exit 0 ;; esac
            fi
            ;;
          explicit)
            if [ "$url" = "https://explicit.invalid/repo.git/info/lfs" ]; then exit 0; fi
            ;;
        esac
        exit 1
      fi
      exit 2
  """).replace("#!/bin/bash", "#!" + shutil.which("bash"), 1)
  for mode in ("ssh", "https", "explicit", "none"):
      with tempfile.TemporaryDirectory() as td:
          state = os.path.join(td, "state")
          bin_dir = os.path.join(td, "bin")
          os.makedirs(state)
          os.makedirs(bin_dir)
          for name in ("config", "pulls"):
              open(os.path.join(state, name), "w").close()
          if mode == "explicit":
              with open(os.path.join(state, "config"), "w") as f:
                  f.write("lfs.url https://explicit.invalid/repo.git/info/lfs\n")
          fake_path = os.path.join(bin_dir, "git")
          with open(fake_path, "w") as f:
              f.write(fake_git)
          os.chmod(fake_path, 0o755)
          script_path = os.path.join(td, "action.sh")
          with open(script_path, "w") as f:
              f.write(lfs_action_run)
          env = os.environ.copy()
          env.update({
              "PATH": bin_dir + os.pathsep + env["PATH"],
              "FAKE_MODE": mode,
              "FAKE_STATE": state,
              "RUNNER_TEMP": td,
              "TMPDIR": td,
              "GITHUB_REPOSITORY": "nixops/nixtache",
              "GITHUB_SERVER_URL": "https://forgejo.invalid",
              "NIXTACHE_GIT_SSH_HOST": "forgejo.invalid",
              "NIXTACHE_UPDATE_GIT_USER": "update-bot",
          })
          result = subprocess.run(
              ["bash", script_path], cwd=td, env=env,
              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
          )
          output = result.stdout
          with open(os.path.join(state, "pulls")) as f:
              pulls = [line.rstrip("\n").split("\t") for line in f if line.strip()]
          config = {}
          with open(os.path.join(state, "config")) as f:
              for line in f:
                  key, value = line.rstrip("\n").split(" ", 1)
                  config[key] = value

          if "secret-token" in output:
              bad("lfs-fetch %s: credential marker leaked into action output" % mode)
          else:
              ok("lfs-fetch %s: endpoint output keeps credentials redacted" % mode)

          if mode == "ssh":
              if result.returncode == 0 and len(pulls) == 1 and pulls[0][0].startswith("ssh://"):
                  ok("lfs-fetch: pure SSH is preferred when its fetch succeeds")
              else:
                  bad("lfs-fetch SSH preference: rc=%d pulls=%r output=%s" % (result.returncode, pulls, output))
              if config.get("lfs.url", "").startswith("ssh://") and config.get("lfs.sshtransfer") == "always":
                  ok("lfs-fetch: pure-SSH endpoint and transport are retained locally")
              else:
                  bad("lfs-fetch: pure-SSH local config drifted: %r" % config)
          elif mode == "https":
              if result.returncode == 0 and len(pulls) == 2 and pulls[0][0].startswith("ssh://") and pulls[1][0].startswith("https://"):
                  ok("lfs-fetch: failed pure SSH falls back to one HTTPS fetch")
              else:
                  bad("lfs-fetch HTTPS fallback: rc=%d pulls=%r output=%s" % (result.returncode, pulls, output))
              if config.get("lfs.url", "").startswith("https://") and config.get("lfs.sshtransfer") == "never":
                  ok("lfs-fetch: HTTPS fallback endpoint is retained locally")
              else:
                  bad("lfs-fetch: HTTPS local config drifted: %r" % config)
          elif mode == "explicit":
              if result.returncode == 0 and len(pulls) == 1 and pulls[0][0] == "https://explicit.invalid/repo.git/info/lfs":
                  ok("lfs-fetch: explicit repository endpoint is used directly")
              else:
                  bad("lfs-fetch explicit endpoint: rc=%d pulls=%r output=%s" % (result.returncode, pulls, output))
              if not os.path.exists(os.path.join(state, "sets")) and config.get("lfs.url") == "https://explicit.invalid/repo.git/info/lfs":
                  ok("lfs-fetch: explicit repository endpoint configuration is preserved")
              else:
                  bad("lfs-fetch: explicit configuration was overwritten: %r" % config)
          else:
              if result.returncode != 0 and len(pulls) == 2 and "pure-SSH" in output and "HTTPS" in output:
                  ok("lfs-fetch: no working transport fails after naming both attempts")
              else:
                  bad("lfs-fetch failure contract: rc=%d pulls=%r output=%s" % (result.returncode, pulls, output))

  with open(report_path, "w") as f:
      f.write("\n".join(lines) + "\n")
  sys.exit(1 if fails else 0)
  PYEOF
  rc=$?
  cat "$report"
  cp "$report" "$out"
  exit "$rc"
''

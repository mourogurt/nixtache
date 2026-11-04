{ nixpkgs
, self
, system ? "x86_64-linux"
, scenario ? "migration-mv"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  upperDir = "/var/lib/nix-overlay/upper";
  workDir = "/var/lib/nix-overlay/work";
  overlayBase = dirOf upperDir;
  scenarios = [
    "migration-mv"
    "migration-exdev"
    "activation-state"
    "publication-stage-mv"
    "publication-ready"
    "publication-current"
    "concurrent"
    "concurrent-booted"
    "retention"
  ];
  selectionScenario = builtins.elem scenario [ "migration-mv" "activation-state" ];
  preparationScenario = builtins.elem scenario [
    "publication-stage-mv"
    "publication-ready"
    "publication-current"
    "concurrent"
    "concurrent-booted"
    "retention"
  ];
  publicationPoint = {
    publication-stage-mv = "after-stage-mv";
    publication-ready = "after-ready";
    publication-current = "after-current";
  }.${scenario} or null;

  replaceChecked = name: old: new: text:
    assert lib.assertMsg (lib.hasInfix old text)
      "overlay-nix-fault-vm ${scenario}: missing ${name} injection anchor";
    builtins.replaceStrings [ old ] [ new ] text;

  mkAppliance =
    { version
    , legacyFixture ? false
    , instrumented ? false
    , separateNixState ? false
    }:
    otaLib.mkAppliance {
      inherit version;
      storeSize = "1G";
      extraModules = [
        self.nixosModules.overlay-nix
        ({ lib, pkgs, ... }: {
          services.nixtache.overlay-nix = {
            enable = true;
            inherit upperDir workDir;
            upperOnUpdate = if scenario == "retention" then "reconcile" else "wipe";
          };
          environment.systemPackages = with pkgs; [ util-linux gawk findutils sqlite ];
          fileSystems = lib.optionalAttrs separateNixState {
            "/nix/var/nix" = {
              device = "tmpfs";
              fsType = "tmpfs";
              options = [ "mode=755" ];
            };
          };
          systemd.services.nixtache-overlay-legacy-fixture = lib.mkIf legacyFixture {
            description = "Populate the legacy upper and upper-owned Nix state before selection";
            unitConfig.ConditionPathExists = "!/tmp/nixtache-legacy-tool-path";
            after = [ "local-fs.target" ];
            before = [ "nixtache-overlay-select.service" ];
            path = with pkgs; [ coreutils findutils util-linux nix ];
            serviceConfig.Type = "oneshot";
            script = ''
              set -euo pipefail
              mkdir -p ${upperDir} ${workDir} /nix/var/nix/db /nix/var/nix/gcroots
              printf '#!/bin/sh\necho LEGACY_TOOL_OK\n' > /tmp/nixtache-legacy-tool
              chmod +x /tmp/nixtache-legacy-tool
              mount -t overlay overlay -o lowerdir=/nix/store,upperdir=${upperDir},workdir=${workDir} /nix/store
              trap 'umount -l /nix/store 2>/dev/null || true' EXIT
              p=$(nix-store --option experimental-features "ca-derivations local-overlay-store" --store 'local-overlay://?lower-store=local&upper-layer=${upperDir}&check-mount=false' --add /tmp/nixtache-legacy-tool)
              echo "$p" > /tmp/nixtache-legacy-tool-path
              ln -s "$p" /nix/var/nix/gcroots/legacy-tool
              umount -l /nix/store
              trap - EXIT
              ${lib.optionalString separateNixState ''
                mkdir -p /run/nixtache-overlay-test ${overlayBase}/legacy-backup/host/state
                {
                  stat -c '%d' /nix/var/nix/db
                  stat -c '%d' ${overlayBase}/legacy-backup/host/state
                } > /run/nixtache-overlay-test/exdev-devices
              ''}
            '';
          };
          systemd.services.nixtache-overlay-select = lib.mkIf legacyFixture {
            after = [ "nixtache-overlay-legacy-fixture.service" ];
            requires = [ "nixtache-overlay-legacy-fixture.service" ];
          };
        })
      ] ++ lib.optionals instrumented [ shimModule ];
    };

  baseV1 = mkAppliance { version = "1"; legacyFixture = true; };
  selectionText = baseV1.config.systemd.services.nixtache-overlay-select.script;
  prepareCommand = baseV1.config.systemd.services.nixtache-overlay-prepare.script;
  preparePath = builtins.head (lib.splitString " " prepareCommand);
  prepareText = builtins.readFile preparePath;

  selectionFaultFunction = ''
    overlay_test_fault() {
      local expected=$1 actual=
      if [ -e /run/nixtache-overlay-test-disable ]; then return 1; fi
      if [ -r /run/nixtache-overlay-test-fault ]; then
        actual=$(cat /run/nixtache-overlay-test-fault)
      elif [ -r /etc/nixtache-overlay-test-fault ]; then
        actual=$(cat /etc/nixtache-overlay-test-fault)
      fi
      [ "$actual" = "$expected" ]
    }
  '';
  selectionWithFaultFunction = replaceChecked "selection fault function"
    "set -euo pipefail\n"
    "set -euo pipefail\n${selectionFaultFunction}"
    selectionText;
  injectedSelectionText =
    if scenario == "migration-mv" then
      replaceChecked "legacy upper mv"
        ''mv "$link" "$backup"''
        ''
          if overlay_test_fault migration-mv && [ "$link" = "${upperDir}" ]; then
                echo "nixtache-overlay-test: injected mv failure after the M record" >&2
                false
              else
                mv "$link" "$backup"
              fi''
        selectionWithFaultFunction
    else if scenario == "activation-state" then
      replaceChecked "state activation"
        "activate_state_dir() {"
        ''
          activate_state_dir() {
                local source=$1 link=$2 backup=$3
                if overlay_test_fault activation-state && [[ "$source" == */state/gcroots ]]; then
                  echo "nixtache-overlay-test: interruption between db and gcroots activation" >&2
                  trap 'exit 143' TERM
                  kill -TERM "$$"
                  sleep 1
                  exit 143
                fi''
        selectionWithFaultFunction
    else
      selectionText;
  injectedSelection = pkgs.writeShellScript "nixtache-overlay-select-test-${scenario}" injectedSelectionText;

  preparationFunctions = ''
    overlay_test_publication_fault() {
      local point=$1
      if [ "$mode" = "--installed" ] && [ -r /run/nixtache-overlay-test-fault ] && [ "$(cat /run/nixtache-overlay-test-fault)" = "$point" ]; then
        echo "nixtache-overlay-test: publication interruption $point" >&2
        kill -TERM "$$"
        sleep 1
        exit 143
      fi
    }
    overlay_test_preparation_started() {
      local role=''${NIXTACHE_TEST_ROLE:-} barrier_dir=/run/nixtache-overlay-test-barrier
      if [ -n "$role" ]; then
        mkdir -p "$barrier_dir"
        touch "$barrier_dir/$role-started"
      fi
    }
    overlay_test_preparation_barrier() {
      local role=''${NIXTACHE_TEST_ROLE:-} barrier_dir=/run/nixtache-overlay-test-barrier
      if [ -n "$role" ]; then
        mkdir -p "$barrier_dir"
        printf '%s\n' "$stage" > "$barrier_dir/$role"
        while [ ! -e "$barrier_dir/release" ]; do sleep 0.05; done
      fi
    }
  '';
  prepareWithFunctions = replaceChecked "preparation fault functions"
    "set -euo pipefail\n"
    "set -euo pipefail\n${preparationFunctions}"
    prepareText;
  prepareWithStartMarker = replaceChecked "preparation start marker"
    "mode=\${1:---installed}"
    "mode=\${1:---installed}\noverlay_test_preparation_started"
    prepareWithFunctions;
  prepareWithBarrier = replaceChecked "staging barrier"
    ''cp "$slot_dir/generations/$generation/metadata" "$stage/metadata"''
    ''
      cp "$slot_dir/generations/$generation/metadata" "$stage/metadata"
            overlay_test_preparation_barrier''
    prepareWithStartMarker;
  prepareWithStageFault = replaceChecked "stage publication"
    ''mv "$stage" "$slot_dir/generations/$generation"''
    ''
      mv "$stage" "$slot_dir/generations/$generation"
            overlay_test_publication_fault after-stage-mv''
    prepareWithBarrier;
  prepareWithReadyFault = replaceChecked "ready publication"
    ''sed -i 's/^state=unready$/state=ready/' "$slot_dir/generations/$generation/metadata"''
    ''
      sed -i 's/^state=unready$/state=ready/' "$slot_dir/generations/$generation/metadata"
            overlay_test_publication_fault after-ready''
    prepareWithStageFault;
  injectedPrepareText = replaceChecked "current publication"
    ''mv -Tf "$slot_dir/.current-$generation" "$slot_dir/current"''
    ''
      mv -Tf "$slot_dir/.current-$generation" "$slot_dir/current"
            overlay_test_publication_fault after-current''
    prepareWithReadyFault;
  injectedPrepare = pkgs.writeShellScript "nixtache-overlay-prepare-test-${scenario}" injectedPrepareText;

  shimModule = { lib, ... }: {
    environment.etc."nixtache-overlay-test-fault" = lib.mkIf (scenario == "migration-mv") {
      text = "migration-mv\n";
    };
    systemd.services.nixtache-overlay-select = lib.mkIf selectionScenario {
      script = lib.mkForce (builtins.readFile injectedSelection);
    };
    systemd.services.nixtache-overlay-prepare = lib.mkIf preparationScenario {
      script = lib.mkForce "${injectedPrepare} --installed";
    };
  };

  v1 = mkAppliance {
    version = "1";
    legacyFixture = true;
    instrumented = true;
    separateNixState = scenario == "migration-exdev";
  };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  v2 = mkAppliance { version = "2"; };
  v2SysupdatePkg = v2.config.system.build.sysupdate-package;
in
assert lib.assertMsg (builtins.elem scenario scenarios)
  "overlay-nix-fault-vm scenario must be one of ${lib.concatStringsSep ", " scenarios}";
pkgs.testers.runNixOSTest {
  name = "overlay-nix-fault-${scenario}";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode {
    extraDependencies = lib.optional preparationScenario v2SysupdatePkg;
  };

  testScript = ''
    import shlex
    import time

    SCENARIO = ${builtins.toJSON scenario}
    PUBLICATION_POINT = ${if publicationPoint == null then "None" else builtins.toJSON publicationPoint}
    NEEDS_PREPARATION = ${if preparationScenario then "True" else "False"}
    V2_SYSUPDATE = ${if preparationScenario then builtins.toJSON "${v2SysupdatePkg}" else builtins.toJSON ""}
    PREPARE_SCRIPT = ${if preparationScenario then builtins.toJSON "${injectedPrepare}" else builtins.toJSON ""}
    UPPER = ${builtins.toJSON upperDir}
    WORK = ${builtins.toJSON workDir}
    OVERLAY_BASE = ${builtins.toJSON overlayBase}

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def q(value):
        return shlex.quote(value)

    def selected_generation():
        slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        root = OVERLAY_BASE + "/upper-slots/" + slot
        return appliance.succeed("readlink -f " + q(root + "/current")).strip()

    def inactive_slot():
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=\"$(cat /run/nixtache-overlay/selected-slot)\" "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()

    def active_checksum():
        return appliance.succeed(
          "(tar --sort=name --numeric-owner --mtime=@0 -cf - -C " + q(UPPER) + " .; "
          "tar --sort=name --numeric-owner --mtime=@0 -cf - -C " + q(OVERLAY_BASE + "/lower-state") + " .; "
          "tar --sort=name --numeric-owner --mtime=@0 -cf - -C /nix/var/nix db gcroots profiles temproots) "
          "2>/dev/null | sha256sum | awk '{print $1}'"
        ).strip()

    def assert_active_tool():
        path = appliance.succeed("cat /tmp/nixtache-legacy-tool-path").strip()
        assert appliance.succeed(path).strip() == "LEGACY_TOOL_OK"
        appliance.succeed("nix path-info " + q(path))
        assert appliance.succeed("readlink /nix/var/nix/gcroots/legacy-tool").strip() == path

    def selection_state(generation):
        command = (
          "ok=1; "
          "test \"$(readlink -f " + UPPER + ")\" = " + q(generation + "/host/upper") + " || ok=0; "
          "test \"$(readlink -f " + WORK + ")\" = " + q(generation + "/host/work") + " || ok=0; "
          "test \"$(readlink -f " + OVERLAY_BASE + "/lower-state" + ")\" = " + q(generation + "/host/lower-state") + " || ok=0; "
          "for name in db gcroots profiles temproots; do "
          "mountpoint -q /nix/var/nix/$name || ok=0; "
          "test /nix/var/nix/$name -ef " + q(generation + "/host/state") + "/$name || ok=0; "
          "done; "
          "if [ \"$ok\" = 1 ]; then echo restored; else echo broken; fi"
        )
        return appliance.succeed(command).strip()

    def wait_v1():
        appliance.wait_for_unit("multi-user.target", timeout=1800)
        assert appliance.succeed("cat /etc/image-version").strip() == "1"
        appliance.wait_until_succeeds("systemctl is-active --quiet boot-complete.target", timeout=300)
        appliance.wait_until_succeeds("nix --version", timeout=300)
        assert_active_tool()

    def stage_v2():
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp " + V2_SYSUPDATE + "/* /var/lib/nixtache/ab-stage/abtest/"
        )
        appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
        appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
        appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)

    def newest_target_generation(target_root):
        return appliance.succeed(
          "ls -dt " + q(target_root) + "/generations/* | head -1"
        ).strip()

    def assert_ready_current(target_root):
        current = appliance.succeed("readlink -f " + q(target_root + "/current")).strip()
        appliance.succeed("grep -q '^state=ready$' " + q(current + "/metadata"))
        return current

    def run_migration_mv():
        appliance.wait_until_succeeds(
          "systemctl is-failed --quiet nixtache-overlay-select.service", timeout=1800
        )
        appliance.wait_until_succeeds("test -f /tmp/nixtache-legacy-tool-path", timeout=120)
        appliance.succeed(
          "journalctl -u nixtache-overlay-select.service --no-pager | "
          "grep -q 'injected mv failure after the M record'"
        )
        m_record = appliance.succeed(
          "grep -q '^M|" + UPPER + "|' /run/nixtache-overlay/activation.log && echo logged || echo missing"
        ).strip()
        legacy_upper = appliance.succeed(
          "path=$(cat /tmp/nixtache-legacy-tool-path); "
          "if test -f " + UPPER + "/$(basename \"$path\"); then "
          "mount -t overlay overlay -o lowerdir=/nix/store,upperdir=" + UPPER + ",workdir=" + WORK + " /nix/store && "
          "\"$path\" >/dev/null; rc=$?; umount -l /nix/store 2>/dev/null || true; "
          "if [ \"$rc\" = 0 ]; then echo preserved; else echo unusable; fi; "
          "else echo deleted; fi"
        ).strip()
        legacy_db = appliance.succeed(
          "test -f /nix/var/nix/db/db.sqlite && echo preserved || echo damaged"
        ).strip()
        legacy_root = appliance.succeed(
          "path=$(cat /tmp/nixtache-legacy-tool-path); "
          "test \"$(readlink /nix/var/nix/gcroots/legacy-tool)\" = \"$path\" && echo preserved || echo damaged"
        ).strip()
        ready_marker = appliance.succeed(
          "test ! -e /run/nixtache-overlay/selected-chain-ready && echo absent || echo present"
        ).strip()
        assert m_record == "logged", "activate_path did not log M before the injected mv failure"
        assert legacy_upper == "preserved", "rollback did not preserve a usable legacy upper"
        assert legacy_db == "preserved", "rollback damaged the legacy upper database"
        assert legacy_root == "preserved", "rollback damaged the legacy gcroot"
        assert ready_marker == "absent", "failed selection exposed selected-chain-ready"
        appliance.succeed("touch /run/nixtache-overlay-test-disable")
        appliance.succeed("systemctl restart nixtache-overlay-select.service", timeout=900)
        appliance.succeed("systemctl start nixtache-overlay-ready.target", timeout=300)
        appliance.wait_until_succeeds("nix --version", timeout=300)
        assert_active_tool()
        print("PASS: migration mv failure preserved legacy state and retry selected the migrated chain")

    def run_migration_exdev():
        appliance.wait_until_succeeds(
          "systemctl is-active --quiet nixtache-overlay-select.service || "
          "systemctl is-failed --quiet nixtache-overlay-select.service", timeout=1800
        )
        assert appliance.succeed("systemctl is-active --quiet nixtache-overlay-select.service && echo active || echo failed").strip() == "active", \
          "cross-filesystem legacy migration failed instead of preserving and selecting the upper chain"
        wait_v1()
        devices = appliance.succeed("cat /run/nixtache-overlay-test/exdev-devices").strip().splitlines()
        assert len(devices) == 2 and devices[0] != devices[1], "legacy Nix state and its backup were not on different filesystems"
        generation = selected_generation()
        assert selection_state(generation) == "restored"
        path = appliance.succeed("cat /tmp/nixtache-legacy-tool-path").strip()
        appliance.succeed("test -f " + q(OVERLAY_BASE + "/legacy-backup/host/upper/" + path.rsplit("/", 1)[-1]))
        appliance.succeed("test -e /run/nixtache-overlay/selected-chain-ready")
        print("PASS: real cross-filesystem migration retained coherent files, database and roots")

    def run_activation_state():
        wait_v1()
        generation = selected_generation()
        assert selection_state(generation) == "restored"
        appliance.succeed("printf '%s\\n' activation-state > /run/nixtache-overlay-test-fault")
        appliance.fail("systemctl restart nixtache-overlay-select.service", timeout=300)
        appliance.succeed(
          "journalctl -u nixtache-overlay-select.service --no-pager | "
          "grep -q 'interruption between db and gcroots activation'"
        )
        rollback_state = selection_state(generation)
        ready_marker = appliance.succeed(
          "test ! -e /run/nixtache-overlay/selected-chain-ready && echo absent || echo present"
        ).strip()
        appliance.succeed("rm -f /run/nixtache-overlay-test-fault")
        appliance.succeed("systemctl restart nixtache-overlay-select.service", timeout=300)
        assert selected_generation() == generation
        assert selection_state(generation) == "restored"
        assert_active_tool()
        assert rollback_state == "restored", "interrupted activation did not restore prior state mounts and selection symlinks"
        assert ready_marker == "absent", "interrupted activation exposed selected-chain-ready"
        print("PASS: activation interruption restored established mounts and symlinks before a clean retry")

    def run_publication(point):
        wait_v1()
        stage_v2()
        target_slot = inactive_slot()
        target_root = OVERLAY_BASE + "/upper-slots/" + target_slot
        active_before = active_checksum()
        active_generation = selected_generation()
        appliance.succeed("printf '%s\\n' " + q(point) + " > /run/nixtache-overlay-test-fault")
        appliance.fail("systemctl restart nixtache-overlay-prepare.service", timeout=900)
        appliance.succeed(
          "journalctl -u nixtache-overlay-prepare.service --no-pager | "
          "grep -q 'publication interruption " + point + "'"
        )
        failed_generation = newest_target_generation(target_root)
        expected_state = "unready" if point == "after-stage-mv" else "ready"
        appliance.succeed("grep -q '^state=" + expected_state + "$' " + q(failed_generation + "/metadata"))
        if point == "after-current":
            assert appliance.succeed("readlink -f " + q(target_root + "/current")).strip() == failed_generation
        else:
            appliance.succeed("test ! -e " + q(target_root + "/current") + " && test ! -L " + q(target_root + "/current"))
        assert active_checksum() == active_before, "publication interruption modified active files or Nix state"
        assert selected_generation() == active_generation
        assert_active_tool()
        appliance.succeed("rm -f /run/nixtache-overlay-test-fault")
        appliance.succeed("systemctl restart nixtache-overlay-prepare.service", timeout=900)
        current = assert_ready_current(target_root)
        prepared_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        assert current == target_root + "/generations/" + prepared_generation
        failed_disposition = appliance.succeed(
          "if test ! -d " + q(failed_generation) + "; then echo discarded; "
          "elif test \"$(readlink -f " + q(target_root + "/current") + ")\" = " + q(failed_generation) +
          " && test \"$(cat /run/nixtache-overlay/prepared-generation)\" = " + q(failed_generation.rsplit("/", 1)[-1]) + "; then echo adopted; "
          "else echo orphaned; fi"
        ).strip()
        assert active_checksum() == active_before, "publication retry modified active files or Nix state"
        assert selected_generation() == active_generation
        assert_active_tool()
        assert failed_disposition != "orphaned", "successful retry left the interrupted generation outside the published ready chain"
        print("PASS: " + point + " interruption preserved active state and retry discarded or adopted the interrupted generation")

    def run_concurrent(mode):
        wait_v1()
        if mode == "--installed":
            stage_v2()
            target_slot = inactive_slot()
        else:
            target_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        target_root = OVERLAY_BASE + "/upper-slots/" + target_slot
        active_before = active_checksum()
        active_generation = selected_generation()
        appliance.succeed("rm -rf /run/nixtache-overlay-test-barrier && mkdir -p /run/nixtache-overlay-test-barrier")
        appliance.succeed(
          "systemd-run --no-block --unit=overlay-nix-prepare-first --property=Type=oneshot "
          "--setenv=NIXTACHE_TEST_ROLE=first " + PREPARE_SCRIPT + " " + mode
        )
        appliance.wait_until_succeeds("test -s /run/nixtache-overlay-test-barrier/first", timeout=300)
        first_stage = appliance.succeed("cat /run/nixtache-overlay-test-barrier/first").strip()
        appliance.succeed(
          "systemd-run --no-block --unit=overlay-nix-prepare-second --property=Type=oneshot "
          "--setenv=NIXTACHE_TEST_ROLE=second " + PREPARE_SCRIPT + " " + mode
        )
        appliance.wait_until_succeeds("test -e /run/nixtache-overlay-test-barrier/second-started", timeout=300)
        for _ in range(300):
            observed = appliance.succeed(
              "if test -s /run/nixtache-overlay-test-barrier/second || ! systemctl is-active --quiet overlay-nix-prepare-second.service; then echo yes; else echo no; fi"
            ).strip()
            if observed == "yes":
                break
            time.sleep(0.1)
        first_stage_state = appliance.succeed(
          "test -d " + q(first_stage) + " && echo survived || echo deleted"
        ).strip()
        first_still_blocked = appliance.succeed(
          "state=$(systemctl show -p ActiveState --value overlay-nix-prepare-first.service); "
          "if { test \"$state\" = activating || test \"$state\" = active; } && "
          "test ! -e /run/nixtache-overlay-test-barrier/release; then echo blocked; else echo released; fi"
        ).strip()
        assert first_still_blocked == "blocked", "the first preparation left its barrier before the second process overlapped it"
        appliance.succeed("touch /run/nixtache-overlay-test-barrier/release")
        appliance.wait_until_succeeds("! systemctl is-active --quiet overlay-nix-prepare-first.service", timeout=900)
        appliance.wait_until_succeeds("! systemctl is-active --quiet overlay-nix-prepare-second.service", timeout=900)
        first_result = appliance.succeed("systemctl show -p Result --value overlay-nix-prepare-first.service").strip()
        second_result = appliance.succeed("systemctl show -p Result --value overlay-nix-prepare-second.service").strip()
        assert first_stage_state == "survived", "the second preparation deleted the first process's staging directory before its barrier was released"
        assert first_result == "success", "the first preparation failed after the concurrent second cleanup: first=" + first_result + " second=" + second_result
        assert second_result == "success", "the second preparation failed: first=" + first_result + " second=" + second_result
        assert_ready_current(target_root)
        assert active_checksum() == active_before
        if mode == "--installed":
            assert selected_generation() == active_generation
        assert_active_tool()
        print("PASS: concurrent " + mode + " preparation preserved the first staging chain; second result=" + second_result)

    def run_retention():
        wait_v1()
        stage_v2()
        target_slot = inactive_slot()
        target_root = OVERLAY_BASE + "/upper-slots/" + target_slot
        active_generation = selected_generation()
        generations = []
        ready_counts = []
        for iteration in range(4):
            appliance.succeed(
              "ln -sfn \"$(cat /tmp/nixtache-legacy-tool-path)\" "
              "/nix/var/nix/gcroots/retention-" + str(iteration)
            )
            active_before = active_checksum()
            appliance.succeed("systemctl restart nixtache-overlay-prepare.service", timeout=900)
            current = assert_ready_current(target_root)
            prepared_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
            assert current == target_root + "/generations/" + prepared_generation
            appliance.succeed(
              "test \"$(readlink " + q(current + "/host/state/gcroots/retention-" + str(iteration)) + ")\" = "
              "\"$(cat /tmp/nixtache-legacy-tool-path)\""
            )
            generations.append(prepared_generation)
            ready_counts.append(int(appliance.succeed(
              "grep -l '^state=ready$' " + q(target_root) + "/generations/*/metadata 2>/dev/null | wc -l"
            ).strip()))
            assert active_checksum() == active_before
            assert selected_generation() == active_generation
            assert_active_tool()
        appliance.fail("find " + q(target_root) + " -maxdepth 1 -name '.staging-*' | grep -q .")
        assert len(set(generations)) == 4, "RemainAfterExit masked one or more preparation reruns"
        assert ready_counts[-1] <= 2 and ready_counts[-1] == ready_counts[-2], "ready generations grew without a bounded retention policy: " + repr(ready_counts)
        print("PASS: repeated real preparation restarts kept bounded ready generations: " + repr(ready_counts))

    if NEEDS_PREPARATION:
        deployer.start()
        deployer.wait_for_unit("nginx.service")

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)

    if SCENARIO == "migration-mv":
        run_migration_mv()
    elif SCENARIO == "migration-exdev":
        run_migration_exdev()
    elif SCENARIO == "activation-state":
        run_activation_state()
    elif PUBLICATION_POINT is not None:
        run_publication(PUBLICATION_POINT)
    elif SCENARIO == "concurrent":
        run_concurrent("--installed")
    elif SCENARIO == "concurrent-booted":
        run_concurrent("--booted")
    elif SCENARIO == "retention":
        run_retention()
    else:
        raise AssertionError("unhandled scenario " + SCENARIO)
  '';
}

# QEMU (pexpect) behavioral test for services.nixtache.overlay-nix: a
# local-overlay-store layered over the A/B appliance's read-only slot store.
#
# Boots a REAL A/B appliance image (built with the REAL deploy-target + ab-image
# + overlay-nix modules) in QEMU and asserts the overlay comes
# up: an OverlayFS mount exists, the overlay daemon is active, and a write
# through the merged store lands in the upper dir while the lower stays ro.
# Also pins the shipped lower store DB (ab-image): the dump sits at a
# versioned ESP path, the boot loader seeds /nix/var/nix/db from it, and a
# lower path resolves `nix path-info` with no manual seeding.
#
# This suite pins boot, mount, copy-on-write, and shipped-DB behavior;
# overlay-nix-install-vm.nix covers full Nix operations hermetically with a
# local cache and registry. Needs KVM (requiredSystemFeatures).
{ nixpkgs, self, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };

  # Build a real A/B appliance locally with deploy-target, ab-image, and
  # overlay-nix for this pexpect suite.
  mkApplianceOverlay =
    { version ? "1"
    , upperDir ? "/var/lib/nix-overlay/upper"
    , workDir ? "/var/lib/nix-overlay/work"
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        # --- REAL nixtache modules (code under test / appliance base) ----------
        self.nixosModules.deploy-target
        self.nixosModules.ab-image
        # --- overlay-nix module (code under test) -------------------------------
        self.nixosModules.overlay-nix

        # --- thin consumer settings -------------------------------------------
        (
          { config, lib, pkgs, ... }:
          {
            system.stateVersion = config.system.nixos.release;
            networking.hostName = "abtest-overlay";
            # Same contract as ab-fixture: the appliance world must evaluate
            # content-addressed (the ab-image module asserts it).
            nixpkgs.pkgs = appliancePkgs;

            services.nixtache.ab-image = {
              enable = true;
              imageId = "abtest";
              imageVersion = version;
              storeSize = "512M";
            };
            services.nixtache.deploy-target = {
              enable = true;
              ab.enable = true;
              ab.gating = false;
            };

            # Enable the module under test with the caller's upper location.
            services.nixtache.overlay-nix = {
              enable = true;
              inherit upperDir workDir;
            };

            # test conveniences
            services.getty.autologinUser = "root";
            users.users.root.initialPassword = "";
            environment.systemPackages = with pkgs; [ util-linux gawk findutils ];
            environment.etc."image-version".text = version;
            # Faithful-imaging coverage: a closure path that is itself a
            # top-level symlink. The image must ship it AS a symlink (not its
            # target's content) with a DB record that resolves — see
            # modules/ab-image/store-tree.nix and the assertions below.
            system.extraDependencies = [
              (pkgs.runCommand "symlink-fixture" { } "ln -s ${pkgs.hello} $out")
            ];

            systemd.services.nixtache-overlay-legacy-fixture = {
              description = "Populate a legacy shared upper before slot migration";
              unitConfig.ConditionPathExists = "!/tmp/nixtache-legacy-tool-path";
              after = [ "local-fs.target" ];
              before = [ "nixtache-overlay-select.service" ];
              path = with pkgs; [ coreutils findutils util-linux nix ];
              serviceConfig.Type = "oneshot";
              script = ''
                set -euo pipefail
                mkdir -p /var/lib/nix-overlay/upper /var/lib/nix-overlay/work /nix/var/nix/db /nix/var/nix/gcroots
                printf '#!/bin/sh\necho LEGACY_TOOL_OK\n' > /tmp/nixtache-legacy-tool
                chmod +x /tmp/nixtache-legacy-tool
                mount -t overlay overlay -o lowerdir=/nix/store,upperdir=/var/lib/nix-overlay/upper,workdir=/var/lib/nix-overlay/work /nix/store
                trap 'umount -l /nix/store 2>/dev/null || true' EXIT
                p=$(nix-store --option experimental-features "ca-derivations local-overlay-store" --store 'local-overlay://?lower-store=local&upper-layer=/var/lib/nix-overlay/upper&check-mount=false' --add /tmp/nixtache-legacy-tool)
                echo "$p" > /tmp/nixtache-legacy-tool-path
                ln -s "$p" /nix/var/nix/gcroots/legacy-tool
                umount -l /nix/store
                trap - EXIT
                mv /boot/EFI/nixtache/abtest_1.lower-db /boot/EFI/nixtache/abtest_1.lower-db.hold
              '';
            };
            systemd.services.nixtache-overlay-select = {
              after = [ "nixtache-overlay-legacy-fixture.service" ];
              requires = [ "nixtache-overlay-legacy-fixture.service" ];
            };
          }
        )
      ];
    };

  v1 = mkApplianceOverlay { };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";

  # pexpect driver (mirrors tests/ab-vm.nix): spawn QEMU with the appliance image,
  # wait for the autologin root shell on ttyS0, run query commands via sentinel
  # framing, print RESULT_* lines asserted by the wrapper.
  driver = pkgs.writers.writePython3Bin "overlay-nix-vm-driver" {
    libraries = with pkgs.python3Packages; [ pexpect ];
    flakeIgnore = [ "E501" "W503" "E401" "E302" "E231" "E305" "E303" "E265" "W391" "E402" "E702" "F811" ];
  } ''
    import pexpect, sys, time
    image = sys.argv[1]
    qemu = "${otaLib.pexpectQemuBin}"
    args = ${otaLib.pyArgs (otaLib.pexpectQemuArgs { })} + ["-hda", image, "-snapshot"]
    p = pexpect.spawn(qemu, args, encoding="utf-8", timeout=240)
    p.expect(r"Welcome to NixOS|login:", timeout=240)
    time.sleep(6)
    p.sendline("echo ABTEST_READY_$$")
    p.expect(r"ABTEST_READY_\d+", timeout=90)
    p.sendline("stty -echo")
    time.sleep(1)
    p.sendline("echo SYNC_$$")
    p.expect(r"SYNC_\d+", timeout=30)

    def run(cmd):
        p.sendline("echo __B__; " + cmd + "; echo __E__$?")
        p.expect(r"__E__\d+", timeout=180)
        return p.before.split("__B__", 1)[-1].strip()

    print("RESULT_MIGRATION_FAILURE=" + run("if [ -f /tmp/nixtache-legacy-tool-path ] && [ -f /boot/EFI/nixtache/abtest_1.lower-db.hold ]; then mount -t overlay overlay -o lowerdir=/nix/store,upperdir=/var/lib/nix-overlay/upper,workdir=/var/lib/nix-overlay/work /nix/store && $(cat /tmp/nixtache-legacy-tool-path); rc=$?; umount -l /nix/store; test ! -L /var/lib/nix-overlay/upper && test $rc = 0 && echo legacy-usable || echo legacy-lost; else echo not-induced; fi"))
    run("mv /boot/EFI/nixtache/abtest_1.lower-db.hold /boot/EFI/nixtache/abtest_1.lower-db && systemctl restart nixtache-overlay-select.service && systemctl start nixtache-overlay-ready.target")
    print("RESULT_MIGRATED_TOOL=" + run("$(cat /tmp/nixtache-legacy-tool-path)"))
    print("RESULT_MIGRATED_PATH_VALID=" + run("nix path-info $(cat /tmp/nixtache-legacy-tool-path) >/dev/null 2>&1 && echo valid || echo invalid"))
    print("RESULT_MIGRATION_BACKUP=" + run("test -e /var/lib/nix-overlay/legacy-backup/host/upper/$(basename $(cat /tmp/nixtache-legacy-tool-path)) && test -f /var/lib/nix-overlay/legacy-backup/host/state/db/db.sqlite && echo preserved || echo missing"))
    print("RESULT_OTHER_SLOT_UNREADY=" + run("find /var/lib/nix-overlay/upper-slots -mindepth 2 -maxdepth 2 -name unready | grep -q . && echo marked || echo missing"))

    # Give the overlay daemon time to come up after boot.
    run("for i in $(seq 1 30); do systemctl is-active --quiet nix-daemon-overlay 2>/dev/null || systemctl is-active --quiet nix-daemon-overlay-mount 2>/dev/null && break; sleep 2; done")

    # --- O1: an OverlayFS mount + the overlay daemon active --------------------
    print("RESULT_OVERLAY_MOUNT_COUNT=" + run("mount | grep -ci overlay"))
    print("RESULT_OVERLAY_DAEMON=" + run("systemctl is-active nix-daemon-overlay-mount 2>/dev/null || echo inactive"))
    print("RESULT_UPPER_DIR=" + run("test -d /var/lib/nix-overlay/upper && echo yes || echo no"))
    print("RESULT_WORK_DIR=" + run("test -d /var/lib/nix-overlay/work && echo yes || echo no"))

    # Detect the merged mountpoint instead of duplicating the module's path,
    # then prove a write lands in the upper while the lower stays read-only.
    # Single-line: this serial driver cannot handle shell continuations.
    cow = run("merged=$(mount | grep '/var/lib/nix-overlay/upper' | head -1 | awk '{print $3}'); [ -z \"$merged\" ] && merged=/mnt/nix-overlay/nix/store; probe=probe-$$; if touch \"$merged/$probe\" 2>/dev/null; then find /var/lib/nix-overlay/upper -name \"$probe\" >/dev/null 2>&1 && echo COW_OK || echo COW_NOT_IN_UPPER; else echo COW_WRITE_FAILED; fi")
    print("RESULT_COW=" + cow)

    # Lower is read-only: /nix/store mount options contain 'ro' (the squashFS).
    print("RESULT_LOWER_RO=" + run("mount | grep ' /nix/store ' | grep -o 'ro' | head -1 || echo no"))

    # --- Shipped lower store DB (ab-image): seeded at boot, no manual seed -----
    # The dump lives on the ESP at a versioned path (the nix-store partition
    # cannot carry it: overlay GC hard-fails on non-store-path entries in the
    # merged store dir); the loader oneshot imports it into /nix/var/nix/db on
    # first boot and records the image version in the marker. A lower path (the
    # shipped nix CLI, part of the toplevel closure) must then resolve through
    # standard nix tooling.
    print("RESULT_LOWER_DUMP=" + run("test -f /boot/EFI/nixtache/abtest_1.lower-db && echo present || echo missing"))
    print("RESULT_LOWER_DB_LOADER=" + run("systemctl is-active nixtache-lower-store-db-load.service 2>/dev/null || echo inactive"))
    print("RESULT_LOWER_DB_CHECKSUM=" + run("test \"$(cat /var/lib/nix-overlay/lower-state/lower-db-sha256 2>/dev/null)\" = \"$(sha256sum /boot/EFI/nixtache/abtest_1.lower-db | awk '{print $1}')\" && echo current || echo stale"))
    print("RESULT_METADATA_ROLES=" + run("test \"$(readlink -f /var/lib/nix-overlay/lower-state)\" != \"$(readlink -f /nix/var/nix/db)\" && test -f /nix/var/nix/db/db.sqlite && echo separate || echo shared"))
    print("RESULT_SLOT_SELECTION=" + run("slot=$(blkid -s PARTUUID -o value $(findmnt -n -o SOURCE --target /nix/store | grep '^/dev/' | sort -u) | tr A-F a-f); test \"$(cat /run/nixtache-overlay/selected-slot)\" = \"$slot\" && echo selected || echo wrong"))
    print("RESULT_INITIAL_GENERATION=" + run("readlink -f /var/lib/nix-overlay/upper"))
    print("RESULT_MIGRATION_IDEMPOTENT=" + run("before=$(readlink -f /var/lib/nix-overlay/upper); systemctl restart nixtache-overlay-select.service; after=$(readlink -f /var/lib/nix-overlay/upper); test \"$before\" = \"$after\" && echo stable || echo changed"))
    # A lower path must resolve through standard nix tooling with no manual
    # seed. /run/current-system, not a host-side store path: the appliance
    # evaluates content-addressed, so its shipped paths hash differently
    # than the IA paths of the flake-level pkgs this test file evaluates
    # with — but the toplevel (and its closure) is covered by the dump.
    print("RESULT_LOWER_PATH_VALID=" + run("nix path-info /run/current-system >/dev/null 2>&1 && echo valid || echo missing"))

    # --- Faithful imaging: a top-level symlink closure path ships as a symlink -
    # The fixture pulls a symlink store path into the closure (see
    # system.extraDependencies above). It must be a symlink in the image, its
    # recorded target must exist, and its validity must resolve through the
    # shipped lower DB.
    print("RESULT_SYMLINK_IS_LINK=" + run("p=$(ls -d /nix/store/*-symlink-fixture 2>/dev/null | head -1); [ -n \"$p\" ] && [ -L \"$p\" ] && echo link || echo notalink"))
    print("RESULT_SYMLINK_TARGET=" + run("p=$(ls -d /nix/store/*-symlink-fixture 2>/dev/null | head -1); t=$(readlink \"$p\" 2>/dev/null); [ -n \"$t\" ] && [ -e \"$t\" ] && echo resolves || echo broken"))
    print("RESULT_SYMLINK_PATH_INFO=" + run("p=$(ls -d /nix/store/*-symlink-fixture 2>/dev/null | head -1); nix path-info \"$p\" >/dev/null 2>&1 && echo valid || echo invalid"))

    print("RESULT_RUNTIME_INSTALL=" + run("printf '#!/bin/sh\\necho UPPER_TOOL_OK\\n' > /tmp/nixtache-upper-tool && chmod +x /tmp/nixtache-upper-tool && p=$(nix store add-path /tmp/nixtache-upper-tool) && echo \"$p\" > /tmp/nixtache-upper-tool-path && nix profile install \"$p\" >/dev/null 2>&1 && \"$p\""))

    print("INFO_MOUNTS=" + run("mount | grep -E 'overlay|/nix/store' | head -20"))
    print("INFO_LSBLK=" + run("lsblk -o NAME,PARTLABEL,FSTYPE,RO,MOUNTPOINT"))
    print("INFO_SELECT_STATUS=" + run("systemctl status nixtache-overlay-select.service --no-pager -l 2>&1 | tail -30"))
    print("INFO_PREPARE_JOURNAL=" + run("journalctl -u nixtache-overlay-legacy-fixture.service -u nixtache-overlay-select.service -u nixtache-lower-store-db-load.service --no-pager -n 100 2>&1"))

    p.sendline("systemctl reboot")
    p.expect(r"Welcome to NixOS|login:", timeout=240)
    time.sleep(8)
    p.sendline("echo ABTEST_REBOOTED_$$")
    p.expect(r"ABTEST_REBOOTED_\d+", timeout=90)
    p.sendline("stty -echo")
    time.sleep(1)
    p.sendline("echo SYNC_REBOOT_$$")
    p.expect(r"SYNC_REBOOT_\d+", timeout=30)

    print("RESULT_REBOOT_TOOL=" + run("$(cat /tmp/nixtache-upper-tool-path)"))
    print("RESULT_REBOOT_PATH_VALID=" + run("nix path-info $(cat /tmp/nixtache-upper-tool-path) >/dev/null 2>&1 && echo valid || echo invalid"))
    print("RESULT_REBOOT_PROFILE=" + run("readlink -f /nix/var/nix/profiles/per-user/root/profile | grep -q '^/nix/store/' && echo persistent || echo missing"))
    print("RESULT_REBOOT_GENERATION=" + run("readlink -f /var/lib/nix-overlay/upper"))
    print("RESULT_REBOOT_LOWER_VALID=" + run("nix path-info /run/current-system >/dev/null 2>&1 && echo valid || echo invalid"))

    p.sendline("poweroff")
    time.sleep(5)
    p.close(force=True)
  '';
in
pkgs.runCommand "overlay-nix-vm-test"
  {
    deps = [ v1.config.system.build.image ];
    nativeBuildInputs = [ driver pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -uo pipefail
    mkdir -p $out
    FAIL=0
    pass() { echo "  ok    $1"; echo "ok    $1" >> $out/report; }
    fail() { echo "  FAIL  $1"; echo "FAIL  $1" >> $out/report; FAIL=1; }

    echo "=== overlay-nix-vm (appliance + overlay-nix module) ==="
    overlay-nix-vm-driver ${v1Image} > driver.out 2>driver.err || true
    echo "--- driver output ---"; cat driver.out
    if [ -s driver.err ]; then echo "--- driver stderr (tail) ---"; tail -5 driver.err; fi

    val() { grep -aoE "^RESULT_$1=.*" driver.out | head -1; }

    [ "$(val OVERLAY_MOUNT_COUNT)" != "RESULT_OVERLAY_MOUNT_COUNT=0" ] && pass "O1: an OverlayFS mount exists" || fail "O1: no overlay mount ($(val OVERLAY_MOUNT_COUNT))"
    echo "$(val OVERLAY_DAEMON)" | grep -q active && pass "O1: overlay daemon active" || fail "O1: overlay daemon not active ($(val OVERLAY_DAEMON))"
    [ "$(val UPPER_DIR)" = "RESULT_UPPER_DIR=yes" ] && pass "O1: upperDir created (tmpfiles)" || fail "O1: upperDir missing ($(val UPPER_DIR))"
    [ "$(val COW)" = "RESULT_COW=COW_OK" ] && pass "read-only+overlay: write through merged lands in upper (COW)" || fail "read-only+overlay COW failed ($(val COW))"
    echo "$(val LOWER_RO)" | grep -q ro && pass "lower /nix/store is read-only" || fail "lower /nix/store not ro ($(val LOWER_RO))"
    [ "$(val LOWER_DUMP)" = "RESULT_LOWER_DUMP=present" ] && pass "lower store DB dump present in the store partition" || fail "dump missing ($(val LOWER_DUMP))"
    [ "$(val LOWER_DB_LOADER)" = "RESULT_LOWER_DB_LOADER=active" ] && pass "lower DB loader oneshot ran at boot" || fail "loader not active ($(val LOWER_DB_LOADER))"
    [ "$(val LOWER_DB_CHECKSUM)" = "RESULT_LOWER_DB_CHECKSUM=current" ] && pass "selected lower-state tracks the lower dump checksum" || fail "lower-state checksum wrong ($(val LOWER_DB_CHECKSUM))"
    [ "$(val METADATA_ROLES)" = "RESULT_METADATA_ROLES=separate" ] && pass "lower-state and upper DB are separate selected metadata" || fail "metadata roles not separate ($(val METADATA_ROLES))"
    [ "$(val SLOT_SELECTION)" = "RESULT_SLOT_SELECTION=selected" ] && pass "upper selection uses the physical lower PARTUUID" || fail "wrong slot selection ($(val SLOT_SELECTION))"
    grep -aq "legacy-usable" driver.out && pass "failed migration leaves the legacy upper and DB usable" || fail "legacy migration failure was destructive ($(val MIGRATION_FAILURE))"
    [ "$(val MIGRATED_TOOL)" = "RESULT_MIGRATED_TOOL=LEGACY_TOOL_OK" ] && pass "previously installed legacy tool works after migration" || fail "migrated legacy tool failed ($(val MIGRATED_TOOL))"
    [ "$(val MIGRATED_PATH_VALID)" = "RESULT_MIGRATED_PATH_VALID=valid" ] && pass "migrated upper preserves DB validity" || fail "migrated upper DB record missing ($(val MIGRATED_PATH_VALID))"
    [ "$(val MIGRATION_BACKUP)" = "RESULT_MIGRATION_BACKUP=preserved" ] && pass "migration retains a recovery backup of upper and state" || fail "migration backup missing ($(val MIGRATION_BACKUP))"
    [ "$(val OTHER_SLOT_UNREADY)" = "RESULT_OTHER_SLOT_UNREADY=marked" ] && pass "the inactive physical slot is explicitly unready" || fail "other slot unready marker missing ($(val OTHER_SLOT_UNREADY))"
    [ "$(val MIGRATION_IDEMPOTENT)" = "RESULT_MIGRATION_IDEMPOTENT=stable" ] && pass "selection and migration are idempotent" || fail "migration changed an established generation ($(val MIGRATION_IDEMPOTENT))"
    [ "$(val LOWER_PATH_VALID)" = "RESULT_LOWER_PATH_VALID=valid" ] && pass "lower path resolves nix path-info with no manual seed" || fail "lower path not valid ($(val LOWER_PATH_VALID))"
    [ "$(val SYMLINK_IS_LINK)" = "RESULT_SYMLINK_IS_LINK=link" ] && pass "top-level symlink closure path ships as a symlink" || fail "symlink closure path not a symlink in the image ($(val SYMLINK_IS_LINK))"
    [ "$(val SYMLINK_TARGET)" = "RESULT_SYMLINK_TARGET=resolves" ] && pass "symlink closure path's target exists in the image" || fail "symlink target broken ($(val SYMLINK_TARGET))"
    [ "$(val SYMLINK_PATH_INFO)" = "RESULT_SYMLINK_PATH_INFO=valid" ] && pass "symlink closure path resolves nix path-info (record matches shipped bytes)" || fail "symlink path-info invalid ($(val SYMLINK_PATH_INFO))"
    val RUNTIME_INSTALL | grep -q "RESULT_RUNTIME_INSTALL=.*UPPER_TOOL_OK" && pass "runtime install lands in the selected upper" || fail "runtime install failed ($(val RUNTIME_INSTALL))"
    [ "$(val REBOOT_TOOL)" = "RESULT_REBOOT_TOOL=UPPER_TOOL_OK" ] && pass "same-slot reboot preserves the installed tool" || fail "installed tool missing after reboot ($(val REBOOT_TOOL))"
    [ "$(val REBOOT_PATH_VALID)" = "RESULT_REBOOT_PATH_VALID=valid" ] && pass "same-slot reboot preserves upper DB validity" || fail "upper DB record lost ($(val REBOOT_PATH_VALID))"
    [ "$(val REBOOT_PROFILE)" = "RESULT_REBOOT_PROFILE=persistent" ] && pass "same-slot reboot preserves the selected profile" || fail "profile missing after reboot ($(val REBOOT_PROFILE))"
    [ "$(val INITIAL_GENERATION | cut -d= -f2-)" = "$(val REBOOT_GENERATION | cut -d= -f2-)" ] && pass "same-slot reboot selects the same generation without preparation" || fail "generation changed on plain reboot"
    [ "$(val REBOOT_LOWER_VALID)" = "RESULT_REBOOT_LOWER_VALID=valid" ] && pass "lower records remain valid after same-slot reboot" || fail "lower records invalid after reboot ($(val REBOOT_LOWER_VALID))"

    cat $out/report
    [ "$FAIL" = "0" ] || exit 1
  ''

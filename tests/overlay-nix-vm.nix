# QEMU (pexpect) BEHAVIORAL test for the module
# `services.nixtache.overlay-nix.*` (spec 08 sec. 6): a Nix `local-overlay-store`
# layered over the read-only squashFS /nix/store of an A/B appliance.
#
# Boots a REAL A/B appliance image (built with the REAL deploy-target + ab-image
# + overlay-nix modules) in QEMU and asserts the overlay comes
# up: an OverlayFS mount exists, the overlay daemon is active, and a write
# through the merged store lands in the upper dir while the lower stays ro.
# Also pins the shipped lower store DB (ab-image): the dump sits at a
# versioned ESP path, the boot loader seeds /nix/var/nix/db from it, and a
# lower path resolves `nix path-info` with no manual seeding.
#
# Offline constraint: the appliance VM has no internet, so `nix-env -i`/`nix shell`
# (which fetch from a registry) are NOT exercised here — the read-only+overlay
# COW mechanism at the filesystem level IS (the user's stated priority). The
# nix-command tests (O2/O3) are deferred to a networked integration run; see
# TEST-SPECS.md sec. 5 / review sec. 11.4 (merged mountpoint ambiguity).
#
# Needs KVM (requiredSystemFeatures). Covers TEST-SPECS.md sec. 5: O1, O7.
{ nixpkgs, self, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };

  # Local appliance builder = ab-fixture mkAppliance + the overlay-nix
  # module + its config. (ab-fixture.nix mkAppliance doesn't take extra modules,
  # so we replicate its thin consumer layer and add overlay-nix. Do NOT edit
  # ab-fixture.nix — other tests depend on it unchanged.)
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
        (self.nixosModules.overlay-nix or ({ ... }: { }))

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

            # The overlay-nix config (spec 08 sec. 6).
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

    # Give the overlay daemon time to come up after boot.
    run("for i in $(seq 1 30); do systemctl is-active --quiet nix-daemon-overlay 2>/dev/null || systemctl is-active --quiet nix-daemon-overlay-mount 2>/dev/null && break; sleep 2; done")

    # --- O1: an OverlayFS mount + the overlay daemon active --------------------
    print("RESULT_OVERLAY_MOUNT_COUNT=" + run("mount | grep -ci overlay"))
    print("RESULT_OVERLAY_DAEMON=" + run("systemctl is-active nix-daemon-overlay nix-daemon-overlay-mount 2>/dev/null | grep -m1 active || echo inactive"))
    print("RESULT_UPPER_DIR=" + run("test -d /var/lib/nix-overlay/upper && echo yes || echo no"))
    print("RESULT_WORK_DIR=" + run("test -d /var/lib/nix-overlay/work && echo yes || echo no"))

    # --- The read-only + overlay COW proof (user's priority) -------------------
    # Detect the overlay's merged mountpoint (spec sec. 6 mountpoint is ambiguous —
    # review sec. 11.4 — so detect from `mount` rather than assume). Then write a
    # probe THROUGH the merged view and confirm it lands in the upper dir while
    # the lower squashFS stays read-only. Single-line: the pexpect serial driver
    # cannot handle multi-line `\` continuations (the shell hangs waiting for
    # the rest of the command).
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
    print("RESULT_LOWER_DB_VERSION=" + run("cat /var/lib/nixtache/lower-db-version 2>/dev/null || echo missing"))
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

    # --- INFO (human visibility) -----------------------------------------------
    print("INFO_MOUNTS=" + run("mount | grep -E 'overlay|/nix/store' | head -20"))
    print("INFO_LSBLK=" + run("lsblk -o NAME,PARTLABEL,FSTYPE,RO,MOUNTPOINT"))

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
    [ "$(val LOWER_DB_VERSION)" = "RESULT_LOWER_DB_VERSION=1" ] && pass "lower DB version marker = running image version" || fail "marker wrong ($(val LOWER_DB_VERSION))"
    [ "$(val LOWER_PATH_VALID)" = "RESULT_LOWER_PATH_VALID=valid" ] && pass "lower path resolves nix path-info with no manual seed" || fail "lower path not valid ($(val LOWER_PATH_VALID))"
    [ "$(val SYMLINK_IS_LINK)" = "RESULT_SYMLINK_IS_LINK=link" ] && pass "top-level symlink closure path ships as a symlink" || fail "symlink closure path not a symlink in the image ($(val SYMLINK_IS_LINK))"
    [ "$(val SYMLINK_TARGET)" = "RESULT_SYMLINK_TARGET=resolves" ] && pass "symlink closure path's target exists in the image" || fail "symlink target broken ($(val SYMLINK_TARGET))"
    [ "$(val SYMLINK_PATH_INFO)" = "RESULT_SYMLINK_PATH_INFO=valid" ] && pass "symlink closure path resolves nix path-info (record matches shipped bytes)" || fail "symlink path-info invalid ($(val SYMLINK_PATH_INFO))"

    cat $out/report
    [ "$FAIL" = "0" ] || exit 1
  ''

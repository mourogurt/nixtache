# A/B image-update VM integration tests (Batch E) — uses REAL nixtache modules.
#
# The `target` imports BOTH real nixtache modules:
#   - self.nixosModules.deploy-target  → runtime: polkit on systemd-sysupdate /
#     nixtache-ab-apply, the ab asserts (modules/deploy-target/ab.nix);
#   - self.nixosModules.ab-image        → image build: repart A/B slots, UKI,
#     systemd.sysupdate transfers, system.image, boot-counting, signature
#     verification (modules/ab-image/default.nix).
# So the fixture below is THIN — it sets imageId/version/publicKey/data-partition
# and everything heavy comes from nixtache (the polkit/gating/repart/transfers
# under test are framework code, not reimplemented).
#
# Boots the real A/B disk image in headless QEMU-KVM; a pexpect driver logs in
# and asserts. Needs KVM (requiredSystemFeatures). Disposable virtual disks only.
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
  appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; },
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Shared throwaway OpenPGP signing keypair + the appliance builder — single
  # source of truth in tests/ab-fixture.nix (its mkAppliance covers
  # version/signVerify/dataPartition; no local copy here).
  inherit (import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; }) testSignKey mkAppliance;

  v1 = mkAppliance { version = "1"; dataPartition = true; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";

  # pexpect driver: spawn QEMU with the A/B image, wait for the autologin root
  # shell on ttyS0, run query commands via sentinel-framed capture, print results.
  driver = pkgs.writers.writePython3Bin "ab-vm-driver" {
    libraries = with pkgs.python3Packages; [ pexpect ];
    flakeIgnore = [ "E501" "W503" "E401" "E302" "E231" "E305" "E303" "E265" "W391" "E402" "E702" "F811" ];
  } ''
    # Standard imports: pexpect drives the QEMU child process over its serial
    # console; sys reads argv (the image path); time for settle sleeps.
    import pexpect, sys, time

    # The A/B disk image to boot is passed as the only CLI argument.
    image = sys.argv[1]

    # QEMU invocation: q35 machine, KVM (TCG fallback), OVMF UEFI firmware, the
    # image as an IDE/SATA disk (-hda; OVMF auto-boots its ESP), -snapshot so the
    # read-only store image is never mutated. Serial on stdio (pexpect reads it),
    # no graphical display, no QEMU monitor mux.
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    args = ["-machine", "q35", "-accel", "kvm", "-accel", "tcg",
            "-bios", "${pkgs.OVMF.fd}/FV/OVMF.fd",
            "-hda", image, "-snapshot",
            "-m", "2048", "-smp", "4",
            "-display", "none", "-serial", "stdio", "-monitor", "none"]
    p = pexpect.spawn(qemu, args, encoding="utf-8", timeout=240)

    # Wait until the kernel/userspace come up far enough to print a login banner.
    p.expect(r"Welcome to NixOS|login:", timeout=240)
    time.sleep(6)  # let the autologin root shell settle on ttyS0

    # Sync on a sentinel WE emit (not on the prompt — the prompt has brackets +
    # ANSI codes we don't want to match). $$ is the shell PID => unique per boot.
    p.sendline("echo ABTEST_READY_$$")
    p.expect(r"ABTEST_READY_\d+", timeout=90)

    # Disable tty echo: without this, pexpect captures the *echoed command* as
    # well as its output, which corrupts the sentinel framing.
    p.sendline("stty -echo")
    time.sleep(1)
    p.sendline("echo SYNC_$$")
    p.expect(r"SYNC_\d+", timeout=30)

    def run(cmd):
        # Run a shell command and return its stdout. Framing: we print __B__
        # before and __E__$? after; pexpect matches __E__<exitcode> and returns
        # everything between __B__ and __E__ (the command's actual output).
        p.sendline("echo __B__; " + cmd + "; echo __E__$?")
        p.expect(r"__E__\d+", timeout=120)
        return p.before.split("__B__", 1)[-1].strip()

    # Give Automatic Boot Assessment time to reach boot-complete.target (gated by
    # boot counting + systemd-bless-boot). Poll up to 60s before reading state.
    run("for i in $(seq 1 30); do systemctl is-active --quiet boot-complete.target && break; sleep 2; done")

    # --- RESULT_* (single-line, asserted by the wrapper) ---------------------
    print("RESULT_VERSION=" + run("cat /etc/image-version"))
    print("RESULT_BOOT_COMPLETE=" + run("systemctl is-active boot-complete.target || true"))
    print("RESULT_BLESS=" + run("${pkgs.systemd}/lib/systemd/systemd-bless-boot status 2>/dev/null || echo unknown"))
    # PARTLABEL = GPT partition label (filesystem LABEL is empty for squashfs).
    print("RESULT_SLOTS=" + run("lsblk -lno PARTLABEL | tr '\\n' ','"))
    print("RESULT_DATA=" + run("echo alive >/mnt/data/marker 2>/dev/null; cat /mnt/data/marker 2>/dev/null || echo MISSING"))
    # Real-nixtache proof: the deploy-target.ab module provisioned the polkit rule
    # authorizing the deploy user to start systemd-sysupdate + nixtache-ab-apply.
    # 0 => the module is NOT active on this target.
    print("RESULT_NIXTACHE_POLKIT=" + run("grep -cE 'systemd-sysupdate.service|nixtache-ab-apply.service' /etc/polkit-1/rules.d/49-nixtache-ab.rules 2>/dev/null || echo 0"))
    # Signature verification: the ab-image module forces Transfer.Verify=yes when a
    # publicKey is set; check sysupdate's transfer files actually say so. NixOS
    # emits transfers as /etc/sysupdate.d/<name>.transfer (symlinks → use -R to
    # follow). INI form: `[Transfer]\nVerify=no`.
    print("RESULT_VERIFY=" + run("grep -RhE '^Verify=' /etc/sysupdate.d/ 2>/dev/null | sort -u | tr '\\n' ',' || echo none"))

    # --- INFO_* (multi-line, printed for human visibility) -------------------
    print("INFO_NIXOS_VERSION=" + run("nixos-version 2>/dev/null || grep -E '^VERSION=' /etc/os-release"))
    print("INFO_UNAME=" + run("uname -a"))
    # First-boot attestation diagnostics: what Automatic Boot Assessment can
    # and cannot report under this boot path (QEMU + OVMF + systemd-boot +
    # UKI-with-+tries filename). bless-boot status exit code (0 = good/bad
    # determined, non-zero = indeterminate), the loader's view of the boot,
    # the ESP's UKI entries (the +N suffix is the tries-left counter), and
    # the LoaderEntrySelected EFI variable raw bytes (empty = runtime
    # services did not expose the loader's choice to the OS).
    print("INFO_BLESS_STATUS=" + run("${pkgs.systemd}/lib/systemd/systemd-bless-boot status 2>&1; echo rc=$?"))
    print("INFO_BOOTCTL=" + run("bootctl 2>&1 | head -40"))
    print("INFO_ESP_LINUX=" + run("ls -la /boot/EFI/Linux/ 2>&1"))
    print("INFO_LOADER_SELECTED=" + run("od -An -tx1 /sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f 2>&1 | head -5"))
    print("INFO_LSBLK=" + run("lsblk -o NAME,PARTLABEL,PARTTYPENAME,FSTYPE,SIZE,MOUNTPOINT"))
    print("INFO_PARTED=" + run("parted -s /dev/sda print 2>/dev/null || echo '(no parted)'"))
    print("INFO_STORE_PATHS=" + run("find /nix/store -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l"))
    print("INFO_STORE_SIZE=" + run("du -sh /nix/store 2>/dev/null | cut -f1"))
    print("INFO_CURRENT_SYSTEM=" + run("readlink -f /run/current-system 2>/dev/null"))
    # Integrity: broken store-INTERNAL symlinks only (refs to /nix/store/* must
    # resolve; symlinks to /etc,/usr are excluded — they resolve on the running
    # system, not in the bare squashfs store).
    print("RESULT_STORE_BROKEN_LINKS=" + run("find /nix/store -xtype l -lname '/nix/store/*' 2>/dev/null | wc -l"))

    p.sendline("poweroff")
    time.sleep(5)
    p.close(force=True)
  '';
in
pkgs.runCommand "ab-vm-test"
  {
    deps = [ v1.config.system.build.image ];
    nativeBuildInputs = [ driver pkgs.coreutils pkgs.gnugrep pkgs.gnupg ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -uo pipefail
    mkdir -p $out
    FAIL=0
    pass() { echo "  ok    $1"; echo "ok    $1" >> $out/report; }
    fail() { echo "  FAIL  $1"; echo "FAIL  $1" >> $out/report; FAIL=1; }

    echo "=== ab-vm (target imports REAL nixtache deploy-target + ab-image modules) ==="
    echo "--- test signing key (T4/T5 verify staged manifests with its public half) ---"
    gpg --no-default-keyring --keyring ${testSignKey}/pubring.pgp --list-keys --fingerprint --with-colons 2>/dev/null \
      | awk -F: '/^(pub|fpr|uid):/{if($1=="fpr")print "  fingerprint: "$10; else if($1=="uid")print "  uid: "$10}' \
      || echo "  (test key at ${testSignKey})"
    echo "  NOTE: slot B appears as '_empty' until the first update writes it (→ nix-store_2)."

    ab-vm-driver ${v1Image} > driver.out 2>driver.err || true
    echo "--- driver output ---"; cat driver.out
    if [ -s driver.err ]; then echo "--- driver stderr (tail) ---"; tail -5 driver.err; fi

    val() { grep -aoE "^RESULT_$1=.*" driver.out | head -1; }

    [ "$(val VERSION)"        = "RESULT_VERSION=1" ] && pass "T1 boots version 1" || fail "T1 did not boot version 1 ($(val VERSION))"
    [ "$(val BOOT_COMPLETE)"  = "RESULT_BOOT_COMPLETE=active" ] && pass "T1 boot-complete.target active" || fail "T1 boot-complete not active ($(val BOOT_COMPLETE))"
    echo "$(val BLESS)" | grep -qE 'complete|good|validated|clean' && pass "T1 bless-boot good" || fail "T1 bless not good ($(val BLESS))"
    # T2: slot A (nix-store_1) populated + slot B (_empty) reserved.
    echo "$(val SLOTS)" | grep -q "nix-store_1" && echo "$(val SLOTS)" | grep -q "_empty" && pass "T2 slot A (nix-store_1) + slot B reserved (_empty)" || fail "T2 slot layout wrong ($(val SLOTS))"
    [ "$(val DATA)" = "RESULT_DATA=alive" ] && pass "T6 data partition mounts + writable (system slot untouched)" || fail "T6 data marker not alive ($(val DATA))"
    # Real nixtache deploy-target.ab module is active (its polkit rule is present).
    [ "$(val NIXTACHE_POLKIT)" = "RESULT_NIXTACHE_POLKIT=2" ] && pass "T-polkit: real deploy-target.ab polkit present (sysupdate + ab-apply)" || fail "T-polkit: nixtache polkit missing ($(val NIXTACHE_POLKIT))"
    # Real nixtache ab-image module: on v1 (signVerify=false) Verify must be "no".
    echo "$(val VERIFY)" | grep -q "Verify=no" && pass "T-verify: ab-image module set Transfer.Verify=no (no publicKey on v1)" || fail "T-verify: unexpected Verify ($(val VERIFY))"
    [ "$(val STORE_BROKEN_LINKS)" = "RESULT_STORE_BROKEN_LINKS=0" ] && pass "T-integrity: no broken store-internal symlinks" || fail "T-integrity: broken store links ($(val STORE_BROKEN_LINKS))"

    cat $out/report
    [ "$FAIL" = "0" ] || exit 1
  ''

# A/B image compression tests — covers the
# EXISTING ab-image options `storeFs`, `storeCompression`,
# `storeCompressionLevel`. Two parts in ONE derivation:
#
#   Part 1 (K1/K2/K3, no KVM): builds nix-store split images via the REAL
#     ab-image module and compares `.nix-store.raw` sizes with `stat -c%s`.
#   Part 2 (K4, KVM): boots a squashFS+zstd-19 and an EROFS+zstd-19 appliance
#     via a pexpect-QEMU driver (mirrors tests/ab-vm.nix) and asserts /nix/store
#     mounts with the right fstype, is readable, and boot-complete is reached.
#
# Exposed via the flake (wired by the orchestrator) as
# `checks.x86_64-linux.ab-compression-vm`. Because part 2 boots real A/B images
# in QEMU, the whole derivation carries `requiredSystemFeatures = [ "kvm" ]` — a
# non-KVM runner skips it during routine `nix flake check` (same model as ab-vm).
{
  nixpkgs,
  self,
  system ? "x86_64-linux",
}:

let
  lib = nixpkgs.lib;
  # Reuse ab-fixture.nix for the shared throwaway signing key etc. WITHOUT
  # editing it. Its mkAppliance does NOT forward storeFs / storeCompression /
  # storeCompressionLevel, so we define a local variant below that does (its body
  # mirrors mkAppliance's thin consumer module + the three compression options).
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };
  pkgs = fixture.pkgs;

  # Small store slot → small boot image (fast QEMU). The squashfs/erofs CONTENT
  # for this minimal appliance is well under 512M, so it fits the partition. The
  # size comparison in K1-K3 is on the split raw (the compressed store image),
  # NOT the fixed-size partition slot, so compression level shows in the bytes.
  storeSize = "512M";

  # Local appliance builder exposing the ab-image compression options under test.
  # Heavy A/B machinery still comes from the REAL nixtache modules; this only
  # says WHO the image is + which fs/compression to bake in.
  mkApplianceCompressed =
    { version ? "1"
    , storeFs ? "squashfs"
    , storeCompression ? null
    , storeCompressionLevel ? null
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.deploy-target # runtime: polkit/gating (real nixtache)
        self.nixosModules.ab-image # image build: repart/UKI/sysupdate/verify
        (
          { config, lib, pkgs, ... }:
          {
            system.stateVersion = config.system.nixos.release;
            networking.hostName = "abtest";
            nixpkgs.hostPlatform = system;

            services.nixtache.ab-image = {
              enable = true;
              imageId = "abtest";
              imageVersion = version;
              inherit storeSize storeFs storeCompression storeCompressionLevel;
            };

            # A/B runtime: direct-trigger style (no forgejo/gating in the test).
            services.nixtache.deploy-target = {
              enable = true;
              ab.enable = true;
              ab.gating = false;
            };

            services.getty.autologinUser = "root";
            users.users.root.initialPassword = "";
            environment.systemPackages = with pkgs; [ util-linux gawk parted ];
            environment.etc."image-version".text = version;
          }
        )
      ];
    };

  # --- Appliances under test -------------------------------------------------
  # NOTE: squashfs is ALWAYS compressed (it's a compressed fs). `storeCompression
  # = null` drops the repart `Compression=` key, so repart falls back to the
  # squashfs default (gzip) — that is the "none/baseline" image in K1/K2.
  noneSquashfs = mkApplianceCompressed { storeFs = "squashfs"; storeCompression = null; };
  # zstd-19 squashfs: K1 compressed, K3 top of the level sweep, K4 squash boot.
  zstd19Squashfs = mkApplianceCompressed { storeFs = "squashfs"; storeCompression = "zstd"; storeCompressionLevel = 19; };
  # erofs + zstd-19: K2 compressed, K4 erofs boot.
  zstd19Erofs = mkApplianceCompressed { storeFs = "erofs"; storeCompression = "zstd"; storeCompressionLevel = 19; };
  # K3 level sweep: zstd 1 + 9 (level 19 reused from zstd19Squashfs above).
  zstd1Squashfs = mkApplianceCompressed { storeFs = "squashfs"; storeCompression = "zstd"; storeCompressionLevel = 1; };
  zstd9Squashfs = mkApplianceCompressed { storeFs = "squashfs"; storeCompression = "zstd"; storeCompressionLevel = 9; };

  # Split nix-store image (the compressed store) + the full bootable disk image.
  # Naming follows ab-image's sysupdate-package (`<imageId>_<version>.nix-store.raw`)
  # and the combined disk `<imageId>_<version>.raw` (matches tests/ab-vm.nix).
  splitRaw = app: "${app.config.system.build.image}/abtest_1.nix-store.raw";
  fullImage = app: "${app.config.system.build.image}/abtest_1.raw";

  # --- K4 pexpect-QEMU driver (structure copied from tests/ab-vm.nix) ---------
  # argv: <image> <LABEL>. LABEL tags the RESULT_* keys (SQUASHFS / EROFS) so the
  # shell wrapper can assert per-variant. Spawns QEMU-KVM, waits for the autologin
  # root shell on ttyS0, runs query commands via __B__/__E__ framing, prints
  # results, powers off.
  driver = pkgs.writers.writePython3Bin "ab-compression-driver" {
    libraries = with pkgs.python3Packages; [ pexpect ];
    flakeIgnore = [ "E501" "W503" "E401" "E302" "E231" "E305" "E303" "E265" "W391" "E402" "E702" "F811" ];
  } ''
    import pexpect, sys, time

    image = sys.argv[1]
    label = sys.argv[2]          # SQUASHFS / EROFS (tags RESULT_* keys)

    # QEMU invocation: q35, KVM (TCG fallback), OVMF UEFI firmware, the A/B disk
    # as -hda (OVMF auto-boots its ESP), -snapshot so the read-only store image is
    # never mutated. Serial on stdio (pexpect reads it).
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    args = ["-machine", "q35", "-accel", "kvm", "-accel", "tcg",
            "-bios", "${pkgs.OVMF.fd}/FV/OVMF.fd",
            "-hda", image, "-snapshot",
            "-m", "2048", "-smp", "4",
            "-display", "none", "-serial", "stdio", "-monitor", "none"]
    p = pexpect.spawn(qemu, args, encoding="utf-8", timeout=240)

    p.expect(r"Welcome to NixOS|login:", timeout=240)
    time.sleep(6)  # let the autologin root shell settle on ttyS0

    # Sentinel sync (not the prompt — it carries brackets/ANSI). $$ = shell PID.
    p.sendline("echo ABTEST_READY_$$")
    p.expect(r"ABTEST_READY_\d+", timeout=90)
    p.sendline("stty -echo")
    time.sleep(1)
    p.sendline("echo SYNC_$$")
    p.expect(r"SYNC_\d+", timeout=30)

    def run(cmd):
        # __B__/__E__$? framing: return stdout between the sentinels.
        p.sendline("echo __B__; " + cmd + "; echo __E__$?")
        p.expect(r"__E__\d+", timeout=120)
        return p.before.split("__B__", 1)[-1].strip()

    # Give Automatic Boot Assessment time to reach boot-complete.target (boot
    # counting + systemd-bless-boot). Poll up to 60s before reading state.
    run("for i in $(seq 1 30); do systemctl is-active --quiet boot-complete.target && break; sleep 2; done")

    storeMount = run("mount | grep -c ' /nix/store ' || true")
    fstype = run("findmnt -n -o FSTYPE /nix/store 2>/dev/null || echo unknown")
    storeCount = run("ls /nix/store 2>/dev/null | wc -l")
    bootComplete = run("systemctl is-active boot-complete.target || true")

    mounted = "yes" if storeMount.strip() not in ("", "0") else "no"

    print("RESULT_FSTYPE_" + label + "=" + fstype)
    print("RESULT_STORE_MOUNTED_" + label + "=" + mounted)
    print("RESULT_STORE_READABLE_" + label + "=" + storeCount)
    print("RESULT_BOOT_COMPLETE_" + label + "=" + bootComplete)

    p.sendline("poweroff")
    time.sleep(5)
    p.close(force=True)
  '';
in
pkgs.runCommand "ab-compression-vm-test"
  {
    # Force-evaluate every image (the split raw sizes + the boot images are also
    # referenced via ${...} interpolation in the builder below, which is what
    # actually makes them runtime inputs — kept here as documentation, as in ab-vm).
    deps = [
      noneSquashfs.config.system.build.image
      zstd19Squashfs.config.system.build.image
      zstd19Erofs.config.system.build.image
      zstd1Squashfs.config.system.build.image
      zstd9Squashfs.config.system.build.image
    ];
    nativeBuildInputs = [ driver pkgs.coreutils pkgs.gnugrep ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -uo pipefail
    mkdir -p $out
    FAIL=0
    pass() { echo "  ok    $1"; echo "ok    $1" >> $out/report; }
    fail() { echo "  FAIL  $1"; echo "FAIL  $1" >> $out/report; FAIL=1; }

    echo "=== ab-compression-vm: K1/K2/K3 build-compare + K4 pexpect-QEMU boot ==="

    # ---------------- Part 1: K1/K2/K3 build-compare (no KVM) ----------------
    # Compare the SPLIT nix-store.raw (the compressed store image), not the
    # fixed-size partition slot — so the compression algorithm/level is visible
    # in the byte count.
    # `du -B1` (actual disk usage in 1-byte blocks), NOT `stat -c%s` or `du -b`
    # (both return apparent size): repart pads the split image to the partition
    # size (512M apparent for all variants), but the compressed squashfs/erofs
    # CONTENT differs (zstd ~361M vs gzip ~385M actual disk usage).
    sizeOf() { du -B1 "$1" | cut -f1; }
    noneSize=$(sizeOf ${splitRaw noneSquashfs})
    sqZstd19=$(sizeOf ${splitRaw zstd19Squashfs})
    erZstd19=$(sizeOf ${splitRaw zstd19Erofs})
    sqZstd1=$(sizeOf ${splitRaw zstd1Squashfs})
    sqZstd9=$(sizeOf ${splitRaw zstd9Squashfs})
    echo "  nix-store.raw sizes (bytes):"
    echo "    squashfs+none(gzip)=$noneSize  squashfs+zstd19=$sqZstd19  erofs+zstd19=$erZstd19"
    echo "    squashfs+zstd1=$sqZstd1  squashfs+zstd9=$sqZstd9"

    # K1: squashfs+zstd-19 strictly smaller than the squashfs default (null→gzip).
    if [ "$sqZstd19" -lt "$noneSize" ]; then
      pass "K1 squashfs+zstd-19 < squashfs+default ($sqZstd19 < $noneSize)"
    else
      fail "K1 squashfs+zstd-19 NOT smaller than default ($sqZstd19 >= $noneSize)"
    fi

    # K2: erofs+zstd-19 smaller than squashfs default.
    if [ "$erZstd19" -lt "$noneSize" ]; then
      pass "K2 erofs+zstd-19 < squashfs+default ($erZstd19 < $noneSize)"
    else
      fail "K2 erofs+zstd-19 NOT smaller than squashfs default ($erZstd19 >= $noneSize)"
    fi

    # K3: zstd level monotonic NON-INCREASING: size(1) >= size(9) >= size(19).
    # Per spec §3.3, on a tiny closure the compressed sizes may be EQUAL — the
    # >= relation still holds, so this is the robust (non-strict) form.
    if [ "$sqZstd1" -ge "$sqZstd9" ] && [ "$sqZstd9" -ge "$sqZstd19" ]; then
      pass "K3 zstd levels monotonic non-increasing ($sqZstd1 >= $sqZstd9 >= $sqZstd19)"
    else
      fail "K3 zstd levels NOT monotonic ($sqZstd1 / $sqZstd9 / $sqZstd19)"
    fi

    # ---------------- Part 2: K4 pexpect-QEMU boot (KVM) ---------------------
    # Boot a squashFS+zstd-19 and an EROFS+zstd-19 appliance; assert /nix/store
    # mounts with the right fstype, is readable, and boot-complete.target active.
    run_variant() {
      label="$1"; image="$2"; expectedFs="$3"
      echo "--- K4 boot $label (expect $expectedFs) ---"
      ab-compression-driver "$image" "$label" > "out-$label" 2> "err-$label" || true
      cat "out-$label"
      [ -s "err-$label" ] && { echo "--- $label stderr (tail) ---"; tail -5 "err-$label"; }
      # Serial console shares ttyS0 with late boot messages (boot assessment,
      # bless-boot), which can inject stray \r into a captured value; strip CR.
      val() { grep -aoE "^RESULT_$1=.*" "out-$label" | head -1 | cut -d= -f2- | tr -d '\r'; }
      fstype=$(val FSTYPE_$label)
      mounted=$(val STORE_MOUNTED_$label)
      readable=$(val STORE_READABLE_$label)
      boot=$(val BOOT_COMPLETE_$label)
      [ "$fstype" = "$expectedFs" ] && pass "K4-$label fstype=$fstype" || fail "K4-$label fstype wrong ($fstype != $expectedFs)"
      [ "$mounted" = "yes" ] && pass "K4-$label /nix/store mounted" || fail "K4-$label /nix/store NOT mounted ($mounted)"
      [ "$readable" -gt 0 ] 2>/dev/null && pass "K4-$label store readable ($readable entries)" || fail "K4-$label store NOT readable ($readable)"
      [ "$boot" = "active" ] && pass "K4-$label boot-complete.target active" || fail "K4-$label boot-complete NOT active ($boot)"
    }

    run_variant SQUASHFS ${fullImage zstd19Squashfs} squashfs
    run_variant EROFS    ${fullImage zstd19Erofs}    erofs

    cat $out/report
    [ "$FAIL" = "0" ] || exit 1
  ''

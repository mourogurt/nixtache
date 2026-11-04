# overlay-nix-ota-invalid-vm — overlay-nix across OTA slot swaps with the
# appliance's shipped lower-store database, loaded at boot.
#
# WHAT THIS SUITE PINS. With the slot closure's validity records shipped in
# the image and loaded at boot, the lower store is a first-class readable
# store: runtime installs are a DELTA (only paths missing from the merged
# store land in the upper). An OTA swap can leave upper closures referencing
# old-lower-only paths. The suite prepares the inactive slot with
# upperOnUpdate = "wipe" | "reconcile" (default "wipe"), injects an
# interrupted preparation and a changed lower-dump checksum, then reuses the
# original slot for a second update. Active files and Nix state must remain
# intact, incomplete generations must stay unready, and reconcile must clone
# the latest active upper rather than a reused slot's stale generation.
#
# Mock packages (the pkgs_1 -> pkgs_2 -> pkgs_3 triangle):
#   pkgs_1 (mock-runtime): a renamed busybox at $out/bin/busybox. Its refs
#     are {glibc, busybox} — the shipped dump registers pkgs_1's whole
#     closure. Baked into v1's lower image ONLY (v2 does not carry it).
#   pkgs_2 (mock-tool): a script whose shebang points at pkgs_1's busybox —
#     a genuine runtime closure reference. Realized into the UPPER on v1;
#     its only ref is pkgs_1, so with the shipped DB in place realize
#     fetches exactly pkgs_2.
#   pkgs_3: `hello` baked only into v2's lower — proves the new lower is
#     visible through the remounted merged store.
#
# Profile leg: pkgs_2 is additionally installed into root's per-user profile
# pre-swap; reconcile preserves the profile target and its repaired closure,
# while wipe removes both. pkgs_4 is installed only after the first swap and
# identifies the latest active upper when the original physical slot is reused.
#
# Variant knobs (flake attr = suite instance):
#   overlayOptions — merged into services.nixtache.overlay-nix (the
#     lifecycle mode: { upperOnUpdate = "reconcile"; } ...; unset = the
#     module default, "wipe").
#   upperTmpfs — move the upper layer to tmpfs (every reboot clears stale
#     upper-owned state and reseeds the lower DB, even without a swap).
#   reconcileDegraded — run nixtache-ab-update with nix-serve stopped, prove
#     failed upper preparation cannot reboot, then boot the unprepared UKI
#     directly and verify target-only recovery after restoring the cache.
#
# Needs KVM. Hermetic: everything comes from the deployer node on the test
# LAN; no internet.
{ nixpkgs, self, system ? "x86_64-linux", overlayOptions ? { }, upperTmpfs ? false, reconcileDegraded ? false, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; } }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system appliancePkgs; };

  # pkgs_1: the lower-only runtime. A renamed busybox keeps multi-call
  # dispatch working: `busybox sh` (applet via argv[1]) requires argv[0] to
  # be exactly "busybox", so the binary is shipped under that name.
  pkgs_1 = pkgs.runCommand "mock-runtime" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';

  # pkgs_2: the upper-layer consumer. The shebang carries pkgs_1's store
  # path, so the reference scanner makes pkgs_1 its only runtime reference —
  # when pkgs_1 is absent from the merged store, execve fails with a hard
  # "bad interpreter: No such file or directory".
  pkgs_2 = pkgs.runCommand "mock-tool" { } ''
    mkdir -p $out/bin
    printf '#!%s/bin/busybox sh\necho tool-ok\n' "${pkgs_1}" > $out/bin/tool
    chmod +x $out/bin/tool
  '';

  pkgs_4 = pkgs.runCommand "mock-reuse-marker" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';

  p1Path = pkgs_1.outPath;
  p2Path = pkgs_2.outPath;
  p4Path = pkgs_4.outPath;
  p1Basename = baseNameOf p1Path;
  p2Basename = baseNameOf p2Path;
  p4Basename = baseNameOf p4Path;
  helloPath = pkgs.hello.outPath;
  helloBasename = baseNameOf helloPath;

  # Throwaway binary-cache keypair: deployer signs, appliance trusts (same
  # pattern as tests/overlay-nix-ab-swap-vm.nix).
  cacheKey = pkgs.runCommand "ota-invalid-cache-key" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export NIX_STATE_DIR=$TMPDIR/nix-state
    mkdir -p $out "$NIX_STATE_DIR"
    nix-store --generate-binary-cache-key ota-invalid-local $out/private $out/public
  '';
  cachePub = builtins.readFile "${cacheKey}/public";

  upperDir = if upperTmpfs then "/tmp/nix-overlay/upper" else "/var/lib/nix-overlay/upper";
  workDir = if upperTmpfs then "/tmp/nix-overlay/work" else "/var/lib/nix-overlay/work";

  # A/B appliance + overlay-nix + test-driver plumbing (backdoor shell on
  # hvc0, virtio in initrd, static test-LAN address). The deployer is the
  # only declared node → 192.168.1.1; the created appliance machine takes .3.
  mkAppliance = { version, extraPackages ? [ ] }:
    fixture.mkAppliance {
      inherit version;
      signVerify = true;
      stagingPath = "http://deployer/ab-stage/abtest";
      storeSize = "1G";
      extraPackages = extraPackages ++ [ pkgs.curl pkgs.gptfdisk ];
      extraModules = [
        self.nixosModules.overlay-nix
        (nixpkgs + "/nixos/modules/testing/test-instrumentation.nix")
        (nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
        ({ lib, ... }: {
          services.nixtache.overlay-nix = {
            enable = true;
            inherit upperDir workDir;
          } // overlayOptions;

          # Hermetic substituter: the deployer's nix-serve (test LAN only).
          # mkForce: a plain assignment would CONCATENATE with the
          # nixpkgs default (cache.nixos.org) and every fetch pay DNS
          # timeouts on the hermetic test LAN.
          nix.settings.substituters = lib.mkForce [ "http://deployer:5000" ];
          nix.settings.trusted-public-keys = [ cachePub ];

          networking.usePredictableInterfaceNames = false;
          networking.interfaces.eth0.ipv4.addresses = [
            { address = "192.168.1.3"; prefixLength = 24; }
          ];
          networking.hosts."192.168.1.1" = [ "deployer" ];
          networking.firewall.enable = false;
        })
      ] ++ lib.optional upperTmpfs {
        # tmpfs upper: wiped by any reboot, lifecycle has nothing to preserve.
        fileSystems."/tmp/nix-overlay" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=755" ];
        };
      };
    };

  v1 = mkAppliance { version = "1"; extraPackages = [ pkgs_1 ]; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  # v2 carries hello (pkgs_3) as the content marker and — crucially — NOT
  # pkgs_1: its lower store cannot satisfy pkgs_2's shebang after the swap.
  v2 = mkAppliance { version = "2"; extraPackages = [ pkgs.hello ]; };
  v2SysupdatePkg = v2.config.system.build.sysupdate-package;
  v3 = mkAppliance { version = "3"; };
  v3SysupdatePkg = v3.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "overlay-nix-ota-invalid";
  globalTimeout = 5400;

  nodes.deployer = { pkgs, ... }: {
    services.nix-serve = {
      enable = true;
      package = pkgs.nix-serve;
      secretKeyFile = "${cacheKey}/private";
      bindAddress = "0.0.0.0";
      port = 5000;
    };
    services.nginx.enable = true;
    services.nginx.virtualHosts."deployer".locations."/ab-stage/" = {
      root = "/var/lib/nixtache";
      extraConfig = "autoindex on;";
    };
    systemd.tmpfiles.rules = [ "d /var/lib/nixtache/ab-stage 1777 root root -" ];
    environment.systemPackages = [ pkgs.gnupg ];
    environment.etc."signing-key".source = "${fixture.testSignKey}/priv.asc";
    # the staged v2 sysupdate-package must fit on the root disk
    virtualisation.diskSize = 8192;
    # pkgs_2 must be servable (realize fetch); pkgs_1's closure must be
    # servable (the reconcile repair re-fetch).
    system.extraDependencies = [ pkgs_2 pkgs_1 pkgs_4 v2SysupdatePkg v3SysupdatePkg ];
    networking.firewall.enable = false;
  };

  testScript = ''
    P1 = "${p1Path}"
    P2 = "${p2Path}"
    P4 = "${p4Path}"
    P1B = "${p1Basename}"
    P2B = "${p2Basename}"
    P4B = "${p4Basename}"
    HELLO_P = "${helloPath}"
    HELLO_B = "${helloBasename}"
    UPPER = "${upperDir}"
    LOWER_STATE = "${dirOf upperDir}/lower-state"
    MODE = ${if overlayOptions ? upperOnUpdate then builtins.toJSON overlayOptions.upperOnUpdate else ''"wipe"''}
    TMPFS = ${if upperTmpfs then "True" else "False"}
    DEGRADED = ${if reconcileDegraded then "True" else "False"}

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    def sign_stage():
        deployer.succeed(
          "export GNUPGHOME=$(mktemp -d) && "
          "gpg --batch --import /etc/signing-key 2>/dev/null && "
          "cd /var/lib/nixtache/ab-stage/abtest && "
          "gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS"
        )

    def stage_v2():
        deployer.succeed("mkdir -p /var/lib/nixtache/ab-stage/abtest")
        deployer.succeed("cp ${v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/")
        sign_stage()

    def stage_v3():
        deployer.succeed(
          "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
          "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
          "cp ${v3SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
        )
        sign_stage()

    # Directory mtimes change when this test adds and removes interruption
    # padding; compare persistent names, contents, links and permissions instead.
    def active_state_checksum():
        return appliance.succeed(
          "(tar --sort=name --numeric-owner --mtime=@0 -cf - -C \"${upperDir}\" .; "
          "tar --sort=name --numeric-owner --mtime=@0 -cf - -C \"${dirOf upperDir}/lower-state\" .; "
          "tar --sort=name --numeric-owner --mtime=@0 -cf - -C /nix/var/nix db gcroots profiles temproots) "
          "2>/dev/null | sha256sum | awk '{print $1}'"
        ).strip()

    def inactive_slot():
        return appliance.succeed(
          "lsblk -nrpo PARTUUID,PARTLABEL | "
          "awk -v active=\"$(cat /run/nixtache-overlay/selected-slot)\" "
          "'BEGIN{IGNORECASE=1} $2 ~ /^nix-store_/ && tolower($1) != active "
          "{print tolower($1); exit}'"
        ).strip()

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")
    # The framework's kernel cmdline carries a double-prefixed regInfo=
    # (/nix/.ro-store/nix/store/<hash>/registration) while the guest mounts
    # the host store share directly at /nix/.ro-store, so the boot-time
    # register-nix-paths.service fails with "No such file or directory" and
    # the deployer's store DB misses the extraDependencies — nix-serve then
    # cannot serve them and the appliance's `nix-store --realize` dies with
    # "no substituter that can build it". Re-load the registration from the
    # actually-mounted path.
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    # v1 must be blessed before the swap, or its remaining boot-counting
    # tries would outrank the freshly installed v2 entry.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    appliance.wait_until_succeeds("nix --version", timeout=300)
    print("OK: v1 appliance booted, overlay-nix up")

    # -- Shipped lower DB: validity out of the box, no manual seed ---------
    # pkgs_1 sits in v1's toplevel closure, so the dump shipped on the ESP
    # registered it at boot: the lower store is a first-class readable store
    # from first contact.
    appliance.succeed("test -f /boot/EFI/nixtache/abtest_1.lower-db")
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet nixtache-lower-store-db-load.service", timeout=120
    )
    appliance.succeed("nix path-info " + P1)
    print("OK: shipped lower DB — pkgs_1 valid out of the box (no manual seed)")

    # -- Realize pkgs_2 into the upper: the delta-only install -------------
    appliance.succeed("nix-store --realize " + P2, timeout=600)
    out = appliance.succeed(P2 + "/bin/tool")
    assert "tool-ok" in out, f"tool did not run on v1 ({out!r})"
    appliance.succeed(f"test -d {UPPER}/{P2B}")
    appliance.fail(f"test -d {UPPER}/{P1B}")
    print("OK: pkgs_2 realized into the upper; pkgs_1 stayed lower-only (shipped DB held)")

    # -- GC probe: pin overlay-GC behaviour on the shipped Nix version -----
    # Root pkgs_2 (it must survive GC), realize an UNROOTED throwaway, GC it,
    # and capture the remount/journal evidence. The suite asserts only the
    # invariants (files gone, store usable, rooted tool alive); the journal
    # capture documents which GC branch Nix takes on the appliance wiring.
    # the root file must be reboot-persistent (a /tmp root dies with the
    # plain-reboot control and would de-root pkgs_2 before the swap).
    appliance.succeed(f"ln -sfn {P2} /nix/var/nix/gcroots/tool-root")

    # -- Profile-install leg (the spec's "recorded installables are replayed"
    # scenario): install the tool into root's per-user profile. Reconcile
    # resolves the profile link target live at cutover and re-realises it.
    # A bare store path is a valid installable — no eval,
    # no network, the path is already valid from the realize above.
    PROF = "/nix/var/nix/profiles/per-user/root/profile"
    appliance.succeed("nix profile install --profile " + PROF + " " + P2)
    out = appliance.succeed(PROF + "/bin/tool")
    assert "tool-ok" in out, f"profile-installed tool did not run on v1 ({out!r})"
    print("OK: tool profile-installed (per-user profile target recorded)")

    appliance.succeed(f"nix-store --realize {HELLO_P}", timeout=600)
    appliance.succeed(f"test -d {UPPER}/{HELLO_B}")
    appliance.succeed("nix-store --gc --print-roots | grep -F /nix/var/nix/gcroots/tool-root")
    # A merged-store GC pass can stop after a deletion batch when it encounters
    # an already-invalid record. Repeat a bounded number of passes; the final
    # upper-file assertion still requires the unrooted path to disappear.
    gc_status, gc_journal = appliance.execute(
      f"gc_status=0; for i in 1 2 3; do "
      f"nix-collect-garbage 2>&1 || gc_status=$?; "
      f"test -d {UPPER}/{HELLO_B} || break; done; "
      "journalctl -u nix-daemon --since -10min | grep -i 'remount' || true; "
      "exit \"$gc_status\""
    )
    print("INFO gc-remount-journal: " + gc_journal[-400:])
    appliance.fail(f"test -d {UPPER}/{HELLO_B}")
    assert gc_status == 0, f"nix-collect-garbage failed with status {gc_status}"
    out = appliance.succeed(P2 + "/bin/tool")
    assert "tool-ok" in out, f"rooted tool broken by GC ({out!r})"
    print("OK: GC removed the unrooted path, rooted tool alive")

    PROFILE_TARGET = appliance.succeed("readlink -f " + PROF).strip()

    def assert_persistent_tool_intact():
      appliance.succeed(f"test -d {UPPER}/{P2B}")
      appliance.succeed("nix path-info " + P2)
      out = appliance.succeed(P2 + "/bin/tool")
      assert "tool-ok" in out, f"persistent upper tool did not run ({out!r})"
      assert appliance.succeed("readlink -f " + PROF).strip() == PROFILE_TARGET

    if MODE == "wipe" and not TMPFS:
      deployer.succeed(
        "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
        "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
        "cd /var/lib/nixtache/ab-stage/abtest && : > SHA256SUMS"
      )
      sign_stage()
      # --wait prevents the assertions from racing the Type=simple update.
      # Use the canonical unit name: --wait against the compatibility alias
      # does not return when the canonical unit deactivates.
      appliance.succeed(
        "systemctl start --wait systemd-sysupdate-update.service", timeout=900
      )
      assert_persistent_tool_intact()
      print("OK: empty sysupdate poll left the upper, DB entry and profile intact")

    if not TMPFS:
      appliance.reboot()
      appliance.wait_for_unit("multi-user.target")
      appliance.wait_until_succeeds("nix --version", timeout=300)
      assert_persistent_tool_intact()
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      print("OK: plain-reboot control — persistent upper survived, tool runs")

    if MODE == "wipe" and not TMPFS:
      stage_v2()
      deployer.succeed(
        "raw=/var/lib/nixtache/ab-stage/abtest/abtest_2.nix-store.raw; "
        "offset=1048576; "
        "byte=$(dd if=\"$raw\" bs=1 skip=\"$offset\" count=1 status=none | od -An -tu1); "
        "flipped=$((byte ^ 1)); "
        "printf '%b' \"$(printf '\\\\%03o' \"$flipped\")\" | "
        "dd of=\"$raw\" bs=1 seek=\"$offset\" count=1 conv=notrunc status=none"
      )
      # Canonical unit name, not the alias — see the --wait comment above.
      appliance.fail(
        "systemctl start --wait systemd-sysupdate-update.service", timeout=900
      )
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      assert_persistent_tool_intact()
      appliance.succeed("systemd-sysupdate vacuum", timeout=300)
      print("OK: tampered update failed without wiping; partial instance vacuumed")

    if TMPFS:
      appliance.reboot()
      appliance.wait_for_unit("multi-user.target")
      appliance.wait_until_succeeds("nix --version", timeout=300)
      appliance.wait_until_succeeds(
        "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
      )
      appliance.wait_until_succeeds(
        "systemctl is-active --quiet nixtache-lower-store-db-load.service", timeout=180
      )
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      appliance.fail(f"test -d {UPPER}/{P2B}")
      appliance.fail("test -e " + PROF)
      out = appliance.succeed(f"nix path-info {P2} 2>&1 || true")
      assert "is not valid" in out, f"tmpfs reboot left a stale DB entry ({out!r})"
      appliance.succeed("nix path-info " + P1)
      marker = appliance.succeed("cat " + LOWER_STATE + "/lower-db-sha256").strip()
      expected_marker = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.lower-db | awk '{print $1}'").strip()
      assert marker == expected_marker, "tmpfs reboot did not reseed v1's lower records"
      appliance.succeed("test -f /run/nixtache-overlay/selected-chain-ready")
      appliance.succeed("nix-store --realize " + P2, timeout=600)
      out = appliance.succeed(P2 + "/bin/tool")
      assert "tool-ok" in out, f"tmpfs store could not realize the tool again ({out!r})"
      appliance.succeed(f"test -d {UPPER}/{P2B}")
      print("TMPFS OK: same-version reboot reset stale state, reseeded v1 and allowed re-realize")

    # -- Stage v2 + sysupdate → slot B → reboot into the new lower ---------
    if DEGRADED:
        deployer.succeed("systemctl stop nix-serve.service")
    active_profile_before = appliance.succeed("readlink -f " + PROF).strip()
    active_before_update = active_state_checksum() if not TMPFS else None
    update_boot_id = appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    stage_v2()
    if DEGRADED:
        appliance.fail("systemctl start nixtache-ab-update.service", timeout=900)
        assert appliance.succeed("cat /proc/sys/kernel/random/boot_id").strip() == update_boot_id, "failed upper preparation rebooted the active slot"
        appliance.succeed(
          "journalctl -u nixtache-ab-update.service -b --no-pager | "
          "grep -q 'upper preparation failed — not rebooting'"
        )
        print("OK: completed install plus failed upper preparation failed the trigger without rebooting")
    else:
        appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: sysupdate wrote v2 to slot B + ESP")

    if not TMPFS:
        target_slot = inactive_slot()
        target_root = f"/var/lib/nix-overlay/upper-slots/{target_slot}"
        if not DEGRADED:
            padding = f"{UPPER}/{'a' * 32}-preparation-padding"
            appliance.succeed(f"dd if=/dev/zero of={padding} bs=1M count=128 status=none")
            active_before_failure = active_state_checksum()
            appliance.succeed("systemctl start --no-block nixtache-overlay-prepare.service")
            appliance.succeed(
              "for i in $(seq 1 1000); do "
              f"if find {target_root} -maxdepth 1 -name '.staging-*' | grep -q .; then "
              "exec systemctl stop nixtache-overlay-prepare.service; fi; "
              "sleep 0.01; done; exit 1", timeout=120
            )
            assert active_state_checksum() == active_before_failure, "interrupted clone modified active state"
            appliance.succeed(f"rm -f {padding}")
        appliance.wait_until_succeeds(
          f"grep -l '^state=unready$' {target_root}/generations/*/metadata", timeout=120
        )
        unready_metadata = appliance.succeed(
          f"grep -l '^state=unready$' {target_root}/generations/*/metadata"
        ).strip().splitlines()
        unready_generation = unready_metadata[0][:-len("/metadata")]
        assert active_state_checksum() == active_before_update, "failed preparation modified active state"
        assert_persistent_tool_intact()
        print("OK: failed preparation left an explicit unready generation and preserved active state")

        if DEGRADED:
            deployer.succeed("systemctl start nix-serve.service")
            print("OK: rebooting directly into the unprepared UKI for target-only boot recovery")
        else:
            active_before_retry = active_state_checksum()
            appliance.succeed("systemctl reset-failed nixtache-overlay-prepare.service")
            appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
            appliance.fail(f"test -e {unready_generation}")
            assert active_state_checksum() == active_before_retry, "target retry modified active state"
            assert_persistent_tool_intact()
            assert appliance.succeed("readlink -f " + PROF).strip() == active_profile_before
            out = appliance.succeed(f"nix path-info {HELLO_P} 2>&1 || true")
            assert "is not valid" in out, f"target lower records leaked into the active DB ({out!r})"
            assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == target_slot
            target_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
            target = f"{target_root}/generations/{target_generation}"
            appliance.succeed(f"grep -q '^state=ready$' {target}/metadata")
            appliance.succeed(f"grep -q '^policy={MODE}$' {target}/metadata")
            if MODE == "reconcile":
                appliance.succeed(f"test -d {target}/host/upper/{P1B}")
                appliance.succeed(f"test -d {target}/host/upper/{P2B}")
                appliance.fail(f"test -d {UPPER}/{P1B}")
                print("OK: old-lower dependency repaired only in the target; active DB/files unchanged")
            appliance.succeed(
              "cp /boot/EFI/nixtache/abtest_2.lower-db /run/nixtache-overlay/changed-lower-db && "
              "cat /run/nixtache-overlay/changed-lower-db >> /boot/EFI/nixtache/abtest_2.lower-db"
            )
            print("OK: retry discarded the incomplete generation; installed lower dump checksum changed")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "2", f"swap failed: booted version {version}, expected 2"
    appliance.wait_until_succeeds("nix --version", timeout=300)
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
    )
    appliance.succeed(
      "mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=" + UPPER + "'"
    )
    # pkgs_3: the v2 lower is visible through the remounted merged store.
    appliance.succeed(f"test -d /nix/store/{HELLO_B}")
    print("OK: booted v2, overlay remounted over the new lower")
    if not TMPFS:
        v2_selected = appliance.succeed(f"readlink -f {target_root}/current").strip()
        v2_generation = v2_selected.rsplit("/", 1)[-1]
        appliance.succeed(f"grep -q '^state=ready$' {v2_selected}/metadata")
        selected_sha = appliance.succeed("sed -n 's/^lower_sha256=//p' " + v2_selected + "/metadata").strip()
        expected_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_2.lower-db | awk '{print $1}'").strip()
        assert selected_sha == expected_sha, "boot recovery did not load the current lower dump"
        if DEGRADED:
            appliance.fail(f"test -e {unready_generation}")
            print("OK: unrelated reboot recovered the unprepared target and blessed a complete upper chain")
        else:
            assert v2_generation != target_generation, "checksum change reused a stale ready generation"
            print("OK: checksum mismatch produced a fresh ready generation during boot recovery")

    if MODE == "wipe":
        appliance.fail(f"test -d {UPPER}/{P2B}")
        out = appliance.succeed(f"nix path-info {P2} 2>&1 || true")
        assert "is not valid" in out, f"wipe left DB entry ({out!r})"
        appliance.fail("test -e " + PROF)
        appliance.succeed("nix --version")
        marker = appliance.succeed("cat " + LOWER_STATE + "/lower-db-sha256").strip()
        expected_marker = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_2.lower-db | awk '{print $1}'").strip()
        assert marker == expected_marker, "wipe did not load v2's lower records"
        print("WIPE OK: no stale upper content, DB entries or profiles; overlay functional")
    elif MODE == "reconcile":
        marker = appliance.succeed("cat " + LOWER_STATE + "/lower-db-sha256").strip()
        expected_marker = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_2.lower-db | awk '{print $1}'").strip()
        assert marker == expected_marker, "reconcile did not load v2's lower records"
        appliance.succeed(f"test -d {UPPER}/{P1B}")
        out = appliance.succeed(P2 + "/bin/tool")
        assert "tool-ok" in out, f"reconcile did not heal the tool ({out!r})"
        out = appliance.succeed(PROF + "/bin/tool")
        assert "tool-ok" in out, f"reconcile did not preserve the profile ({out!r})"
        print("RECONCILE OK: target-only repair healed the old-lower dependency and preserved the profile")

    if not TMPFS:
        appliance.succeed("nix-store --realize " + P4, timeout=600)
        out = appliance.succeed(P4 + "/bin/busybox echo reuse-marker-ok")
        assert "reuse-marker-ok" in out, f"v2 reuse marker did not run ({out!r})"
        appliance.succeed(f"test -d {UPPER}/{P4B}")
        active_v2_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
        reused_slot = inactive_slot()
        assert reused_slot != active_v2_slot
        stale_current = appliance.succeed(
          f"readlink -f /var/lib/nix-overlay/upper-slots/{reused_slot}/current"
        ).strip()
        stage_v3()
        appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
        appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_3", timeout=900)
        appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_3+*.efi", timeout=300)
        active_before_reuse = active_state_checksum()
        appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
        assert appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip() == reused_slot
        reused_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
        reused_target = f"/var/lib/nix-overlay/upper-slots/{reused_slot}/generations/{reused_generation}"
        assert reused_target != stale_current, "slot reuse revived its stale generation"
        appliance.succeed(f"grep -q '^state=ready$' {reused_target}/metadata")
        appliance.succeed(f"grep -q '^source_slot={active_v2_slot}$' {reused_target}/metadata")
        appliance.succeed(f"grep -q '^source_generation={v2_generation}$' {reused_target}/metadata")
        if MODE == "reconcile":
            appliance.succeed(f"test -d {reused_target}/host/upper/{P4B}")
            appliance.succeed(f"test -d {reused_target}/host/upper/{P2B}")
        else:
            appliance.fail(f"test -d {reused_target}/host/upper/{P4B}")
            appliance.fail(f"test -d {reused_target}/host/upper/{P2B}")
        assert active_state_checksum() == active_before_reuse, "slot reuse modified the active v2 state"
        out = appliance.succeed(P4 + "/bin/busybox echo reuse-marker-ok")
        assert "reuse-marker-ok" in out, f"active v2 marker broke during slot reuse ({out!r})"
        print("OK: reused slot prepared a fresh generation from the latest active upper")

        appliance.reboot()
        appliance.wait_for_unit("multi-user.target")
        assert appliance.succeed("cat /etc/image-version").strip() == "3"
        appliance.wait_until_succeeds("nix --version", timeout=300)
        selected_reuse = appliance.succeed(
          f"readlink -f /var/lib/nix-overlay/upper-slots/{reused_slot}/current"
        ).strip()
        assert selected_reuse == reused_target, "reused slot did not select its new generation"
        if MODE == "reconcile":
            out = appliance.succeed(P4 + "/bin/busybox echo reuse-marker-ok")
            assert "reuse-marker-ok" in out, f"reused slot lost the latest active marker ({out!r})"
            out = appliance.succeed(P2 + "/bin/tool")
            assert "tool-ok" in out, f"reused slot lost its repaired tool ({out!r})"
            out = appliance.succeed(PROF + "/bin/tool")
            assert "tool-ok" in out, f"reused slot lost its profile ({out!r})"
        else:
            appliance.fail(f"test -d {UPPER}/{P4B}")
            out = appliance.succeed(f"nix path-info {P4} 2>&1 || true")
            assert "is not valid" in out, f"wipe reuse retained a stale DB entry ({out!r})"
        print("OK: reused slot booted with the newly prepared upper generation")

    print("PASS: overlay-nix-ota-invalid matrix leg (mode=" + str(MODE) + ")")
  '';
}

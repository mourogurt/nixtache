# overlay-nix-ota-invalid-vm — overlay-nix across OTA slot swaps on the
# SHIPPED world A (the appliance image carries the lower store database —
# see the lower-store-db openspec change).
#
# WHAT THIS SUITE PINS. With the slot closure's validity records shipped in
# the image and loaded at boot, the lower store is a first-class readable
# store: runtime installs are a DELTA (only paths missing from the merged
# store land in the upper), and an OTA swap replaces the lower with paths
# the upper may reference — leaving dangling references (binaries failing
# with a missing interpreter, database entries claiming validity for files
# absent from the merged view) unless a lifecycle policy acts. The suite
# boots a real appliance, verifies the shipped DB works out of the box
# (no manual seed), then swaps and pins the lifecycle behaviour
# (upperOnUpdate = "wipe" | "reconcile"; the default is "wipe").
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
# Profile leg (the spec's "recorded installables are replayed" scenario):
#   pkgs_2 is additionally `nix profile install`ed into root's per-user
#   profile pre-swap; reconcile resolves the profile link target live at
#   cutover and asserts the tool runs through the profile link again
#   post-swap (wipe variant asserts the negative).
#
# Variant knobs (flake attr = suite instance):
#   overlayOptions — merged into services.nixtache.overlay-nix (the
#     lifecycle mode: { upperOnUpdate = "reconcile"; } ...; unset = the
#     module default, "wipe").
#   upperTmpfs — move the upper layer to tmpfs (every reboot clears stale
#     upper-owned state and reseeds the lower DB, even without a swap).
#
# Needs KVM. Hermetic: everything comes from the deployer node on the test
# LAN; no internet.
{ nixpkgs, self, system ? "x86_64-linux", overlayOptions ? { }, upperTmpfs ? false, reconcileDegraded ? false, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; } }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
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

  p1Path = pkgs_1.outPath;
  p2Path = pkgs_2.outPath;
  p1Basename = baseNameOf p1Path;
  p2Basename = baseNameOf p2Path;
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
    system.extraDependencies = [ pkgs_2 pkgs_1 v2SysupdatePkg ];
    networking.firewall.enable = false;
  };

  testScript = ''
    P1 = "${p1Path}"
    P2 = "${p2Path}"
    P1B = "${p1Basename}"
    P2B = "${p2Basename}"
    HELLO_P = "${helloPath}"
    HELLO_B = "${helloBasename}"
    UPPER = "${upperDir}"
    MODE = ${if overlayOptions ? upperOnUpdate then builtins.toJSON overlayOptions.upperOnUpdate else ''"wipe"''}
    TMPFS = ${if upperTmpfs then "True" else "False"}
    DEGRADED = ${if reconcileDegraded then "True" else "False"}

    def create_ab_machine(**kwargs):
        # -accel kvm then -accel tcg: TCG fallback for CI runners whose build
        # sandbox cannot open /dev/kvm (EPERM) — without the fallback the QEMU
        # dies before the QMP handshake and the suite looks like a host kill.
        start_command = [
            "${pkgs.qemu_test}/bin/qemu-kvm",
            "-machine", "q35",
            "-cpu", "max",
            "-accel", "kvm",
            "-accel", "tcg",
            "-bios", "${pkgs.OVMF.fd}/FV/OVMF.fd",
            "-m", "3072",
            "-smp", "4",
            "-drive", "file=${v1Image},id=drive1,if=none,werror=report,snapshot=on",
            "-device", "virtio-blk-pci,drive=drive1,bootindex=1",
            "-netdev", "vde,id=vlan1,sock=$QEMU_VDE_SOCKET_1",
            "-device", "virtio-net-pci,netdev=vlan1,mac=52:54:00:12:01:03",
        ]
        machine = create_machine(start_command=" ".join(start_command), **kwargs)
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
    appliance.succeed(f"nix-store --add-root /var/lib/nixtache/tool-root -r {P2}")

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
    gc_journal = appliance.succeed(
      "nix-collect-garbage 2>&1; journalctl -u nix-daemon --since -10min "
      "| grep -i 'remount' || true"
    )
    print("INFO gc-remount-journal: " + gc_journal[-400:])
    appliance.fail(f"test -d {UPPER}/{HELLO_B}")
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
      appliance.succeed("systemctl start --wait systemd-sysupdate.service", timeout=900)
      assert_persistent_tool_intact()
      assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "1"
      print("OK: empty sysupdate poll left the upper, DB entry and profile intact")

    if not TMPFS:
      appliance.reboot()
      appliance.wait_for_unit("multi-user.target")
      appliance.wait_until_succeeds("nix --version", timeout=300)
      assert_persistent_tool_intact()
      assert appliance.succeed("cat /etc/image-version").strip() == "1"
      assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "1"
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
      appliance.fail("systemctl start --wait systemd-sysupdate.service", timeout=900)
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
      assert appliance.succeed("cat /var/lib/nixtache/lower-db-version").strip() == "1"
      assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "1"
      appliance.succeed("nix-store --realize " + P2, timeout=600)
      out = appliance.succeed(P2 + "/bin/tool")
      assert "tool-ok" in out, f"tmpfs store could not realize the tool again ({out!r})"
      appliance.succeed(f"test -d {UPPER}/{P2B}")
      print("TMPFS OK: same-version reboot reset stale state, reseeded v1 and allowed re-realize")

    # -- Stage v2 + sysupdate → slot B → reboot into the new lower ---------
    # The degraded variant cuts the substituter (nix-serve) before the swap:
    # nginx (port 80) still serves the sysupdate staging, but the reconcile
    # repair pass finds no cache — the unit must fail red without breaking
    # the boot, keep its lifecycle marker behind and heal on the next boot
    # once the cache returns, even though the lower-DB marker is current.
    if DEGRADED:
        deployer.succeed("systemctl stop nix-serve.service")
    stage_v2()
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: sysupdate wrote v2 to slot B + ESP")

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

    if MODE == "wipe":
        appliance.fail(f"test -d {UPPER}/{P2B}")
        out = appliance.succeed(f"nix path-info {P2} 2>&1 || true")
        assert "is not valid" in out, f"wipe left DB entry ({out!r})"
        appliance.fail("test -e " + PROF)
        appliance.succeed("nix --version")
        assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "2"
        assert appliance.succeed("cat /var/lib/nixtache/lower-db-version").strip() == "2"
        print("WIPE OK: no stale upper content, DB entries or profiles; overlay functional")
    elif MODE == "reconcile":
        assert appliance.succeed("cat /var/lib/nixtache/lower-db-version").strip() == "2"
        if DEGRADED:
            appliance.wait_until_succeeds(
              "systemctl is-failed nixtache-overlay-lifecycle.service", timeout=600
            )
            appliance.fail(P2 + "/bin/tool")
            assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "1"
            appliance.succeed("nix --version")
            print("RECONCILE-DEGRADED OK: unit red, boot fine, lifecycle retry pending")
            deployer.succeed("systemctl start nix-serve.service")
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet boot-complete.target", timeout=300
            )
            appliance.reboot()
            appliance.wait_for_unit("multi-user.target")
            appliance.wait_until_succeeds("nix --version", timeout=300)
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
            )
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet nixtache-overlay-lifecycle.service", timeout=600
            )
            assert appliance.succeed("cat /etc/image-version").strip() == "2"
            assert appliance.succeed("cat /var/lib/nixtache/lower-db-version").strip() == "2"
            assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "2"
            out = appliance.succeed(P2 + "/bin/tool")
            assert "tool-ok" in out, f"boot retry did not heal the tool ({out!r})"
            appliance.succeed(f"test -d {UPPER}/{P1B}")
            out = appliance.succeed(PROF + "/bin/tool")
            assert "tool-ok" in out, f"boot retry did not heal the profile ({out!r})"
            print("RECONCILE-RETRY OK: current lower-DB marker did not consume lifecycle retry")
        else:
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet nixtache-overlay-lifecycle.service", timeout=600
            )
            assert appliance.succeed("cat /var/lib/nixtache/last-boot-image-version").strip() == "2"
            appliance.succeed(f"test -d {UPPER}/{P1B}")
            out = appliance.succeed(P2 + "/bin/tool")
            assert "tool-ok" in out, f"reconcile did not heal the tool ({out!r})"
            jout = appliance.succeed(
              "journalctl -u nixtache-overlay-lifecycle.service 2>&1 || true"
            )
            assert "disappeared" in jout, f"verify pass saw no danglers ({jout[-400:]!r})"
            out = appliance.succeed(PROF + "/bin/tool")
            assert "tool-ok" in out, f"reconcile did not replay the profile ({out!r})"
            print("RECONCILE OK: dangling ref healed (pkgs_1 re-fetched), profile replayed")

    print("PASS: overlay-nix-ota-invalid matrix leg (mode=" + str(MODE) + ")")
  '';
}

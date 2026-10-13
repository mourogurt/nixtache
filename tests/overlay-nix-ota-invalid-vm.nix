# overlay-nix-ota-invalid-vm — the replication research suite for overlay-nix
# across OTA slot swaps (world-A construct: see the design of the
# ota-stabilization openspec change).
#
# WHY THIS SUITE EXISTS. On a nixtache appliance the overlay store shares ONE
# database with the "lower" store handle, so `nix-store --realize` pulls FULL
# closures into the upper layer and the upper survives slot swaps by accident
# of closure completeness (world B). The upstream-intended overlay design
# (world A: a lower store with its own database) keeps the upper as a DELTA —
# and there, an OTA swap replaces the lower with paths the upper references,
# leaving dangling references (binaries failing with a missing interpreter,
# database entries claiming validity for files absent from the merged view).
# This suite CONSTRUCTS world A on the real appliance (validity records
# seeded into the database without any file access) and pins the hazard plus
# the lifecycle-mitigation behaviour (upperOnUpdate = "wipe" | "reconcile",
# wired in a later task of the same change).
#
# Mock packages (the pkgs_1 -> pkgs_2 -> pkgs_3 triangle):
#   pkgs_1 (mock-runtime): a renamed busybox at $out/bin/busybox. Its refs
#     are {glibc, busybox} — so the SEED registers pkgs_1's whole closure.
#     Baked into v1's lower image ONLY (v2 does not carry it).
#   pkgs_2 (mock-tool): a script whose shebang points at pkgs_1's busybox —
#     a genuine runtime closure reference. Realized into the UPPER on v1;
#     its only ref is pkgs_1, so with the seed in place realize fetches
#     exactly pkgs_2.
#   pkgs_3: `hello` baked only into v2's lower — proves the new lower is
#     visible through the remounted merged store.
#
# Seeding mechanics (proven against Nix 2.34.8, the shipped version):
#   the deployer emits 5-line-per-path validity records (path, bare-base16
#   narHash, narSize, deriver-or-empty, ref-count + refs) from
#   `nix path-info --json`; the appliance pipes them into
#   `nix-store --load-db` — which registers validity with ZERO file access.
#   (--register-validity must NOT be used: it canonicalises metadata,
#   chmod-ing through the merged view, which makes OverlayFS copy lower
#   files up and destroys the lower-only premise.)
#
# Variant knobs (flake attr = suite instance):
#   overlayOptions — merged into services.nixtache.overlay-nix (the
#     lifecycle mode once the option exists: { upperOnUpdate = "wipe"; } …).
#   upperTmpfs — move the upper layer to tmpfs (the "nothing to preserve"
#     branch: lifecycle behaviour degenerates, only overlay health asserted
#     after the swap).
#
# Needs KVM. Hermetic: everything comes from the deployer node on the test
# LAN; no internet.
{ nixpkgs, self, system ? "x86_64-linux", overlayOptions ? { }, upperTmpfs ? false, reconcileDegraded ? false }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };

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

  # Deployer-side validity-record generator: closure of pkgs_1 -> one file of
  # 5-line records consumable by `nix-store --load-db`. Runs INSIDE the
  # deployer VM (it has the real nix database with pkgs_1's closure); the
  # base64 narHash from `nix path-info --json` is re-encoded as bare base16,
  # which is the format `nix-store --dump-db` emits.
  makeValidityScript = pkgs.writeShellScript "make-validity" ''
    set -euo pipefail
    out="$1"
    p='${p1Path}'
    closure=$(nix-store -q --requisites "$p")
    args=""
    for q in $closure; do args="$args $q"; done
    nix path-info --json $args > /tmp/pi.json
    python3 - <<'PYEOF' "$out"
    import base64, binascii, json, sys
    pi = json.load(open("/tmp/pi.json"))
    lines = []
    for path, info in pi.items():
        h = info["narHash"]
        # SRI ("sha256-…") or prefixed ("sha256:…") — strip either.
        for prefix in ("sha256:", "sha256-"):
            if h.startswith(prefix):
                h = h[len(prefix):]
                break
        raw = base64.b64decode(h + "==")
        h16 = binascii.hexlify(raw).decode()
        refs = info["references"]
        lines.append(path)
        lines.append(h16)
        lines.append(str(info["narSize"]))
        lines.append(info.get("deriver") or "")
        lines.append(str(len(refs)))
        lines.extend(refs)
    open(sys.argv[1], "w").write("\n".join(lines) + "\n")
    PYEOF
  '';
in
pkgs.testers.runNixOSTest {
  name = "overlay-nix-ota-invalid";
  globalTimeout = 5400;

  nodes.deployer = { pkgs, ... }: {
    services.nix-serve = {
      enable = true;
      package = pkgs.nix-serve-ng;
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
    # the staged v2 sysupdate-package must fit on the root disk
    virtualisation.diskSize = 8192;
    environment.systemPackages = [ pkgs.python3 ];
    # pkgs_2 must be servable (realize fetch); pkgs_1's closure must be in
    # the DB (seed generation) AND servable (the reconcile repair re-fetch).
    system.extraDependencies = [ pkgs_2 pkgs_1 v2SysupdatePkg ];
    # the seed generator uses the new CLI (nix path-info --json)
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    networking.firewall.enable = false;
    environment.etc."make-validity".source = makeValidityScript;
  };

  testScript = ''
    P1 = "${p1Path}"
    P2 = "${p2Path}"
    P1B = "${p1Basename}"
    P2B = "${p2Basename}"
    HELLO_P = "${helloPath}"
    HELLO_B = "${helloBasename}"
    UPPER = "${upperDir}"
    MODE = ${if overlayOptions ? upperOnUpdate then builtins.toJSON overlayOptions.upperOnUpdate else "None"}
    TMPFS = ${if upperTmpfs then "True" else "False"}
    DEGRADED = ${if reconcileDegraded then "True" else "False"}

    def create_ab_machine(**kwargs):
        start_command = [
            "${pkgs.qemu_test}/bin/qemu-kvm",
            "-machine", "q35",
            "-cpu", "max",
            "-accel", "kvm",
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

    deployer.start()
    deployer.wait_for_unit("nix-serve.service")
    deployer.wait_for_unit("nginx.service")

    # ── World-A construct: seed pkgs_1's closure into the appliance DB ────
    # The records register validity with zero file access, so pkgs_1's files
    # stay lower-only (no OverlayFS copy-up) and realize(pkgs_2) fetches
    # exactly pkgs_2 — the upper becomes a true delta, as in the
    # upstream-intended overlay design.
    deployer.succeed("/etc/make-validity /var/lib/nixtache/ab-stage/seed.txt")
    deployer.succeed("head -5 /var/lib/nixtache/ab-stage/seed.txt")

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

    appliance.succeed(
      "curl -sf http://deployer/ab-stage/seed.txt | nix-store --load-db"
    )
    appliance.succeed("nix path-info " + P1)
    print("OK: pkgs_1 closure seeded into the DB (validity without content)")

    # ── Realize pkgs_2 into the upper: the delta-only install ─────────────
    appliance.succeed("nix-store --realize " + P2, timeout=600)
    out = appliance.succeed(P2 + "/bin/tool")
    assert "tool-ok" in out, f"tool did not run on v1 ({out!r})"
    appliance.succeed(f"test -d {UPPER}/{P2B}")
    appliance.fail(f"test -d {UPPER}/{P1B}")
    print("OK: pkgs_2 realized into the upper; pkgs_1 stayed lower-only (seed held)")

    # ── GC probe: pin overlay-GC behaviour on the shipped Nix version ─────
    # Root pkgs_2 (it must survive GC), realize an UNROOTED throwaway, GC it,
    # and capture the remount/journal evidence. The suite asserts only the
    # invariants (files gone, store usable, rooted tool alive); the journal
    # capture documents which GC branch Nix takes on the appliance wiring.
    # the root file must be reboot-persistent (a /tmp root dies with the
    # plain-reboot control and would de-root pkgs_2 before the capture).
    appliance.succeed(f"nix-store --add-root /var/lib/nixtache/tool-root -r {P2}")
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

    # ── Plain-reboot control (no update): a persistent upper must survive ─
    # (tmpfs upper: nothing to preserve — skip to the swap leg.)
    if not TMPFS:
      appliance.reboot()
      appliance.wait_for_unit("multi-user.target")
      appliance.wait_until_succeeds("nix --version", timeout=300)
      out = appliance.succeed(P2 + "/bin/tool")
      assert "tool-ok" in out, f"upper did not survive plain reboot ({out!r})"
      print("OK: plain-reboot control — upper survived, tool runs")

    # ── Stage v2 + sysupdate → slot B → reboot into the new lower ─────────
    # The degraded variant cuts the substituter (nix-serve) before the swap:
    # nginx (port 80) still serves the sysupdate staging, but the reconcile
    # repair pass finds no cache — the unit must fail red without breaking
    # the boot, keep its marker and heal on a manual retry once the cache
    # returns.
    if DEGRADED:
        deployer.succeed("systemctl stop nix-serve.service")
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2SysupdatePkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
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
        # ── wipe: the pre-update unit cleared the upper at cutover ────────
        appliance.fail(f"test -d {UPPER}/{P2B}")
        out = appliance.succeed(f"nix path-info {P2} 2>&1 || true")
        assert "is not valid" in out, f"wipe left DB entry ({out!r})"
        appliance.succeed("nix --version")
        print("WIPE OK: no stale upper content or DB entries; overlay functional")
    elif MODE == "reconcile":
        if DEGRADED:
            # repair finds no cache: red unit, intact boot, marker kept.
            appliance.wait_until_succeeds(
              "systemctl is-failed nixtache-overlay-reconcile.service", timeout=600
            )
            appliance.fail(P2 + "/bin/tool")
            appliance.succeed("test -e /var/lib/nixtache/overlay-reconcile-pending")
            appliance.succeed("nix --version")
            print("RECONCILE-DEGRADED OK: unit red, boot fine, marker kept")
            # cache returns → manual retry heals everything.
            deployer.succeed("systemctl start nix-serve.service")
            appliance.succeed("systemctl start nixtache-overlay-reconcile.service", timeout=600)
            out = appliance.succeed(P2 + "/bin/tool")
            assert "tool-ok" in out, f"retry did not heal the tool ({out!r})"
            appliance.succeed(f"test -d {UPPER}/{P1B}")
            appliance.fail("test -e /var/lib/nixtache/overlay-reconcile-pending")
            print("RECONCILE-RETRY OK: healed after the cache returned, marker consumed")
        else:
            appliance.wait_until_succeeds(
              "systemctl is-active --quiet nixtache-overlay-reconcile.service", timeout=600
            )
            appliance.succeed(f"test -d {UPPER}/{P1B}")
            out = appliance.succeed(P2 + "/bin/tool")
            assert "tool-ok" in out, f"reconcile did not heal the tool ({out!r})"
            appliance.fail("test -e /var/lib/nixtache/overlay-reconcile-pending")
            print("RECONCILE OK: dangling ref healed (pkgs_1 re-fetched), tool runs")
    else:
        # ── none (baseline): the hazard, exactly as designed ──────────────
        appliance.fail(P2 + "/bin/tool")
        print("NONE OK: tool fails after swap (missing interpreter) — the hazard")
        # DB still claims pkgs_1 valid; its files are gone from the merged view.
        out = appliance.succeed("nix path-info " + P1 + " 2>&1 || true")
        assert "is not valid" not in out, f"pkgs_1 unexpectedly invalidated ({out!r})"
        vout = appliance.succeed("nix-store --verify 2>&1 || true")
        assert "disappeared" in vout, f"verify did not report danglers ({vout!r})"
        print("NONE OK: verify reports the dangling database entries")

    print("PASS: overlay-nix-ota-invalid matrix leg (mode=" + str(MODE) + ")")
  '';
}

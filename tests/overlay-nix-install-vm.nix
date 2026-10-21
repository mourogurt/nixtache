# QEMU (runNixOSTest) CONTRACT for overlay-nix: FULL working nix over a
# read-only lower store (spec 08 sec. 6). The point of overlay-nix is to restore a
# normal nix on an A/B appliance (`nix.enable=false`, /nix/store ro squashFS) —
# not just `nix-store` ops but the everyday nix surface.
#
# Covers (hermetic — a deployer node runs nix-serve-ng with `hello` and `vim`
# pre-seeded; a LOCAL nixpkgs path is registered so `nix run/shell/build
# nixpkgs#<x>` resolve without internet):
#   O2  `nix-store --realize` a package from the cache → lands in upper, runs.
#   O-delta  `nix-store --realize` of a lower-valid path copies NOTHING into
#       the upper (installs are delta against the valid lower).
#   O3  `nix run nixpkgs#hello` and `nix shell nixpkgs#hello -c hello` (full-nix UX).
#   O-build `nix build nixpkgs#hello` → output in upper.
#   O8  `nix path-info` sees BOTH the lower (system) closure and the upper path.
#   O4  `nix profile install` → `nix profile remove` → `nix-collect-garbage`
#       deletes the upper-only path but NEVER the lower.
#   O5  upperDir on the persistent root FS (per-node qcow2 ext4) → vim
#       installed into the upper layer survives `machine.reboot()`.
#   O6  upperDir on tmpfs (`/tmp/nix-overlay/upper`) → the upper layer is
#       wiped by `machine.reboot()` (by design) and the overlay mount comes
#       back up. NOTE: the spec's "`vim --version` fails" assertion is not
#       expressible in this harness — the node's lower store is the HOST
#       store (9p) which contains vim (the test closure references it), so
#       vim stays visible from the lower. Asserted instead: upper wiped +
#       merged store functional post-reboot (vim resolves from the lower).
#
# Reboot mechanics: nodes are started with `allow_reboot=True` (no `-no-reboot`
# qemu flag) and `machine.reboot()` injects ctrl-alt-delete via the monitor;
# the node's root FS is a per-node qcow2 ext4 (virtualisation.diskImage
# default), so /var/lib survives while tmpfs mounts do not. The driver
# re-connects to the backdoor root shell after the guest comes back.
#
# RED until modules/overlay-nix/default.nix lands (option absent → node eval
# refuses). Needs KVM. Substituters: local deployer only (hermetic); for live
# CI runs swap `--option substituters https://cache.nixos.org/` until the
# mirror-fix commit lands.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # The packages the appliance installs. Pre-computed store paths → `nix-store
  # --realize` fetches exactly these (+ closure) from the deployer cache.
  hello = pkgs.hello;
  helloPath = hello.outPath;
  helloBasename = baseNameOf helloPath;
  vimBasename = baseNameOf pkgs.vim.outPath;

  # Throwaway binary-cache keypair: deployer signs, appliance trusts.
  # NIX_STATE_DIR: nix-store --generate-binary-cache-key initializes the store
  # state dir ($NIX_STATE_DIR/profiles) even for keygen; the default
  # /nix/var/nix is read-only in the build sandbox.
  cacheKey = pkgs.runCommand "overlay-cache-key" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export NIX_STATE_DIR=$TMPDIR/nix-state
    mkdir -p $out "$NIX_STATE_DIR"
    nix-store --generate-binary-cache-key overlay-test-local $out/private $out/public
  '';
  cachePub = builtins.readFile "${cacheKey}/public";

  # Shared appliance wiring: overlay-nix + hermetic substituter + local
  # nixpkgs registry. `upperDir`/`workDir` come from the caller (persistent
  # root FS vs tmpfs — O5 vs O6).
  mkApplianceNode = { upperDir, workDir }: {
    imports = [
      # Empty-module fallback when the module is absent (graceful degradation
      # instead of an attrset-missing eval crash).
      (self.nixosModules.overlay-nix or ({ ... }: { }))
    ];
    # overlay-nix: bring a FULL working nix over the read-only lower via
    # local-overlay-store. The module re-enables nix (review: mkOverride 900
    # true, beats the appliance profile's normal-priority nix.enable=false —
    # NO mkForce) and points the daemon at the local-overlay store.
    services.nixtache.overlay-nix = {
      enable = true;
      inherit upperDir workDir;
    };

    # Hermetic substituter: the deployer cache only (no internet).
    nix.settings.substituters = [ "http://deployer:5000" ];
    nix.settings.trusted-public-keys = [ cachePub ];
    nix.settings.experimental-features = [ "nix-command" "flakes" "local-overlay-store" ];

    # LOCAL nixpkgs registry so `nix run/shell/build nixpkgs#<x>` resolve to
    # the flake input's source (no github fetch). The source lands in the
    # appliance store because it's referenced here.
    nix.registry.nixpkgs.to = { type = "path"; path = "${nixpkgs}"; };

    environment.systemPackages = [ pkgs.nix ];
    networking.firewall.enable = false;
    # nixpkgs eval (nix profile install nixpkgs#vim) wants more than the 1G
    # default.
    virtualisation.memorySize = 2048;
  };
in
pkgs.testers.runNixOSTest {
  name = "overlay-nix-install";
  globalTimeout = 3600;

  nodes.deployer = { pkgs, ... }: {
    services.nix-serve = {
      enable = true;
      package = pkgs.nix-serve-ng;
      secretKeyFile = "${cacheKey}/private";
      bindAddress = "0.0.0.0";
      port = 5000;
    };
    # pre-seed hello + vim + the local nixpkgs source so nix-serve can serve them
    environment.systemPackages = [ hello pkgs.vim ];
    networking.firewall.enable = false;
  };

  # O2-O5: upperDir on the persistent root FS (the node's qcow2 ext4).
  nodes.appliance = mkApplianceNode {
    upperDir = "/var/lib/nix-overlay/upper";
    workDir = "/var/lib/nix-overlay/work";
  };

  # O6: upperDir on tmpfs — the upper layer is wiped with the reboot.
  nodes.applianceTmpfs = lib.mkMerge [
    (mkApplianceNode {
      upperDir = "/tmp/nix-overlay/upper";
      workDir = "/tmp/nix-overlay/work";
    })
    {
      # qemu-vm disregards plain `fileSystems` for test VMs (mkVMOverride) —
      # VM mounts go through virtualisation.fileSystems.
      virtualisation.fileSystems."/tmp/nix-overlay" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=755" ];
      };
    }
  ];

  testScript = ''
    deployer.start()
    deployer.wait_for_unit("nix-serve.service")

    appliance.start(allow_reboot=True)
    # overlay-nix brings nix back; poll for a WORKING nix (not a specific unit
    # name — that's the implementing agent's choice).
    appliance.wait_until_succeeds("nix --version")

    # -- O2: nix-store --realize hello from the cache → upper layer, runs -----
    appliance.succeed("nix-store --realize ${helloPath}", timeout=240)
    out = appliance.succeed("${helloPath}/bin/hello")
    assert "Hello, world" in out, f"O2 FAIL: hello did not run ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${helloBasename}")
    print("O2 OK: nix-store --realize → runs → in upper")

    # -- O-delta: a lower-valid path is never copied into the upper -----------
    # The overlay's lower-store=local reads the node's nix DB, which registers
    # the toplevel closure — so realizing a member of it (the shipped nix CLI)
    # is a no-op for the upper layer; only genuinely missing paths (hello/vim)
    # land there.
    appliance.succeed("nix-store --realize ${pkgs.nix.outPath}", timeout=120)
    appliance.fail("test -d /var/lib/nix-overlay/upper/${baseNameOf pkgs.nix.outPath}")
    print("O-delta OK: lower-valid path realized without an upper copy")

    # -- O3: full-nix UX — `nix run` and `nix shell` over the overlay ---------
    out = appliance.succeed("nix run nixpkgs#hello", timeout=240)
    assert "Hello, world" in out, f"O3-run FAIL: nix run did not work ({out!r})"
    out = appliance.succeed("nix shell nixpkgs#hello -c hello", timeout=240)
    assert "Hello, world" in out, f"O3-shell FAIL: nix shell did not work ({out!r})"
    print("O3 OK: nix run + nix shell work over the overlay")

    # -- O-build: `nix build nixpkgs#hello` → output realized into upper ------
    out = appliance.succeed(
      "nix build nixpkgs#hello --no-link --print-out-paths", timeout=240
    ).strip()
    assert out.startswith("/nix/store/"), f"O-build FAIL: bad out path ({out!r})"
    appliance.succeed(f"test -d /var/lib/nix-overlay/upper/$(basename {out})")
    print("O-build OK: nix build output realized into upper")

    # -- O8: nix path-info sees BOTH lower (system closure) and upper (hello) --
    appliance.succeed("nix path-info /run/current-system")  # lower closure visible
    pi = appliance.succeed("nix path-info --all")
    assert "${helloBasename}" in pi, "O8 FAIL: upper path (hello) not listed"
    print("O8 OK: path-info sees lower closure + upper path")

    # -- O4: profile install → profile remove → GC deletes the upper-only
    #        path, NEVER the lower (spec sec. 5.5) -------------------------------
    appliance.succeed("nix profile install nixpkgs#hello", timeout=300)
    out = appliance.succeed("/root/.nix-profile/bin/hello")
    assert "Hello, world" in out, f"O4 FAIL: profile-installed hello did not run ({out!r})"
    # pinned by the profile GC root — present in the upper layer
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${helloBasename}")
    appliance.succeed("nix profile remove hello", timeout=120)
    # remove creates a new profile generation; the OLD generation still roots
    # hello until the history is wiped (same for `nix-env -e` generations).
    appliance.succeed("nix profile wipe-history", timeout=120)
    appliance.succeed("nix-collect-garbage", timeout=240)
    # unpinned + collected from upper...
    appliance.fail("test -d /var/lib/nix-overlay/upper/${helloBasename}")
    # ...but the lower store (system closure) is read-only and MUST be untouched.
    appliance.succeed("nix path-info /run/current-system")
    print("O4 OK: profile remove + GC deleted the upper path, lower store intact")

    # -- O5: upperDir on the persistent root FS — the install survives reboot -
    # Probe the cache first: right after boot the test LAN may still be coming
    # up, and a failed first narinfo fetch makes nix plan a full source build.
    appliance.wait_until_succeeds(
      "nix path-info --store http://deployer:5000 ${pkgs.vim.outPath}", timeout=240
    )
    appliance.succeed("nix profile install nixpkgs#vim", timeout=600)
    out = appliance.succeed("/root/.nix-profile/bin/vim --version")
    assert "VIM" in out, f"O5 FAIL: vim did not run before reboot ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    appliance.reboot()
    appliance.wait_until_succeeds("nix --version", timeout=300)
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
    )
    out = appliance.succeed("/root/.nix-profile/bin/vim --version")
    assert "VIM" in out, f"O5 FAIL: vim lost after reboot ({out!r})"
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${vimBasename}")
    print("O5 OK: vim installed in the persistent upper survived a reboot")
    appliance.shutdown()

    # -- O6: upperDir on tmpfs — the install is GONE after reboot (by design),
    #        the overlay mount itself comes back up ---------------------------
    applianceTmpfs.start(allow_reboot=True)
    applianceTmpfs.wait_until_succeeds("nix --version", timeout=300)
    # Same boot-timing guard as O5 (this node installs right after boot).
    applianceTmpfs.wait_until_succeeds(
      "nix path-info --store http://deployer:5000 ${pkgs.vim.outPath}", timeout=240
    )
    applianceTmpfs.succeed("nix-store --realize ${pkgs.vim.outPath}", timeout=600)
    out = applianceTmpfs.succeed("${pkgs.vim.outPath}/bin/vim --version")
    assert "VIM" in out, f"O6 FAIL: vim did not run before reboot ({out!r})"
    applianceTmpfs.succeed("test -d /tmp/nix-overlay/upper/${vimBasename}")
    applianceTmpfs.reboot()
    applianceTmpfs.wait_until_succeeds(
      "systemctl is-active --quiet nix-daemon-overlay-mount.service", timeout=180
    )
    # The spec asserts `vim --version` FAILS after the reboot — true on a real
    # appliance (the squashFS lower lacks vim, so a wiped upper removes it).
    # In this harness the lower is the HOST store (9p), which contains vim
    # (the test closure references it), so vim stays runnable from the lower.
    # The faithful assertions here: the tmpfs upper IS wiped ...
    applianceTmpfs.fail("test -d /tmp/nix-overlay/upper/${vimBasename}")
    # ... and the remounted overlay is functional — vim now resolves from the
    # LOWER layer through the merged view.
    out = applianceTmpfs.succeed("${pkgs.vim.outPath}/bin/vim --version")
    assert "VIM" in out, f"O6 FAIL: merged store broken after reboot ({out!r})"
    print("O6 OK: tmpfs upper wiped on reboot (vim gone), overlay mount active")
  '';
}

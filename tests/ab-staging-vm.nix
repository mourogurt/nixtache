# QEMU (runNixOSTest) REAL-RUN test of the A/B staging retain-GC (spec 06 §«retain»,
# review §11.1). Complements the pure-eval script-text checks in ab-existing.nix
# (V1) by actually RUNNING `nixtache-ab-gc` against a populated staging dir and
# verifying the post-GC state end-to-end — including that the re-signed
# SHA256SUMS.gpg GPG-verifies against the public keyring (the exact thing the
# old "leave .gpg stale" bug broke on Verify=yes targets).
#
# Two nodes:
#   withkey — signingKeyFile set    → GC deletes old version + RE-SIGNS manifest
#   nokey   — signingKeyFile = null → GC removes the (stale) .gpg
#
# Targets EXISTING code (modules/runner/ab.nix GC) → green on a KVM box.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  fixture = import ./ab-fixture.nix { inherit nixpkgs self system; };
  inherit (fixture) testSignKey;

  stage = "/var/lib/nixtache/ab-stage/myserver";

  # One runner-host node. `signingKey` controls ONLY the module's signingKeyFile
  # (what GC does); the pre-stage oneshot always lays down a signed manifest with
  # the test key (so the nokey node starts with a "stale" .gpg to be removed).
  mkHost = signingKey: { pkgs, lib, ... }: {
    imports = [ self.nixosModules.runner ];
    services.nginx.enable = true;
    services.nixtache.runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache = { enable = true; domain = "localhost"; port = 5000; };
      instances.default.tokenFile = toString /dev/null;
      secrets.cachePrivateKey = toString /dev/null;
      store.path = "/";
      deploy.ab = {
        enable = true;
        runnerHost = "localhost";
        stagingPath = "/var/lib/nixtache/ab-stage";
        retain = 2; # keep newest 2 of {1,2,3} → delete v1
        signingKeyFile = lib.mkIf (signingKey != null) signingKey;
      };
    };
    # We test the host-side GC service, not CI → container off.
    containers.runner.autoStart = lib.mkForce false;
    # Plain HTTP cache vhost (no real domain / LetsEncrypt in the VM).
    services.nginx.virtualHosts."localhost".forceSSL = lib.mkForce false;
    services.nginx.virtualHosts."localhost".enableACME = lib.mkForce false;
    environment.systemPackages = with pkgs; [ gnupg coreutils diffutils ];

    # Pre-populate the staging dir with 3 versioned artifacts + a signed manifest.
    systemd.services.ab-pre-stage = {
      description = "Pre-populate ab-stage with versioned artifacts + signed manifest";
      wantedBy = [ "multi-user.target" ];
      before = [ "nixtache-ab-gc.service" ];
      path = with pkgs; [ coreutils gnupg ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -euo pipefail
        mkdir -p ${stage}
        # 3 versions (retain=2 will drop v1)
        for v in 1 2 3; do
          head -c $((100*1024)) /dev/urandom > ${stage}/abtest_''${v}.nix-store.raw
          head -c $(( 50*1024)) /dev/urandom > ${stage}/abtest_''${v}.efi
        done
        ( cd ${stage} && sha256sum *.raw *.efi > SHA256SUMS )
        # sign with the test key (both nodes start signed; nokey will have GC drop it)
        GNUPGHOME=$(mktemp -d); export GNUPGHOME
        gpg --batch --import "${testSignKey}/priv.asc" 2>/dev/null
        ( cd ${stage} && gpg --batch --yes --detach-sign -o SHA256SUMS.gpg SHA256SUMS )
        rm -rf "$GNUPGHOME"
        echo "ab-pre-stage: laid down 3 versions + signed manifest at ${stage}"
      '';
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "ab-staging-gc";

  nodes = {
    withkey = mkHost "${testSignKey}/priv.asc";
    nokey = mkHost null;
  };

  testScript = ''
    # ── withkey: GC deletes v1 + RE-SIGNS the manifest (key readable on host) ─
    withkey.start()
    withkey.wait_for_unit("ab-pre-stage.service")
    # initial state: 3 versions + a signed manifest
    withkey.succeed("test -f ${stage}/abtest_1.nix-store.raw")
    withkey.succeed("test -f ${stage}/SHA256SUMS.gpg")
    # snapshot the pre-GC signature → it MUST differ from the post-GC one
    pre_gpg = withkey.succeed("sha256sum ${stage}/SHA256SUMS.gpg")

    withkey.succeed("systemctl start nixtache-ab-gc.service")
    # v1 gone (both .raw and .efi), v2/v3 kept
    withkey.fail("test -e ${stage}/abtest_1.nix-store.raw")
    withkey.fail("test -e ${stage}/abtest_1.efi")
    withkey.succeed("test -f ${stage}/abtest_2.nix-store.raw")
    withkey.succeed("test -f ${stage}/abtest_3.nix-store.raw")
    # SHA256SUMS regenerated to match exactly the survivors
    withkey.succeed("cd ${stage} && sha256sum *.raw *.efi | sort > /tmp/now && sort SHA256SUMS > /tmp/before && diff /tmp/before /tmp/now")
    # .gpg was RE-SIGNED (content changed) and the new signature VERIFIES
    post_gpg = withkey.succeed("sha256sum ${stage}/SHA256SUMS.gpg")
    assert pre_gpg != post_gpg, "withkey FAIL: .gpg not re-signed (still stale)"
    withkey.succeed(
      "GNUPGHOME=$(mktemp -d) gpg --no-default-keyring --keyring ${testSignKey}/pubring.pgp "
      "--verify ${stage}/SHA256SUMS.gpg ${stage}/SHA256SUMS"
    )
    print("withkey OK: GC dropped v1, kept v2/v3, regenerated SHA256SUMS, re-signed .gpg verifies")

    # ── nokey: GC removes the (stale) .gpg when no signing key is configured ──
    nokey.start()
    nokey.wait_for_unit("ab-pre-stage.service")
    # the pre-stage laid down a .gpg (simulating a prior-key signed manifest)
    nokey.succeed("test -f ${stage}/SHA256SUMS.gpg")
    nokey.succeed("systemctl start nixtache-ab-gc.service")
    nokey.fail("test -e ${stage}/SHA256SUMS.gpg")
    nokey.succeed("test -f ${stage}/SHA256SUMS")  # regenerated, unsigned
    # v1 still dropped, v2/v3 kept (GC deletion logic is independent of signing)
    nokey.fail("test -e ${stage}/abtest_1.nix-store.raw")
    nokey.succeed("test -f ${stage}/abtest_3.nix-store.raw")
    print("nokey OK: GC removed stale .gpg (no signing key), deletion logic intact")
  '';
}

# Shared A/B test fixture for nixtache (used by tests/ab-vm.nix, the dogfood
# nixosConfigurations in flake.nix, and the ab-deploy-test app). ONE definition
# of the test appliance + the throwaway signing keypair — no duplication.
#
# The appliance imports the REAL nixtache modules (deploy-target + ab-image) so
# the polkit/gating/repart/transfers/verify under test are framework code.
{ nixpkgs, self, system ? "x86_64-linux" }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};

  # Throwaway OpenPGP signing keypair generated at build time. priv.asc signs
  # staged manifests (server side); pubring.pgp verifies them (target side).
  testSignKey = pkgs.runCommand "abtest-sign-key" { nativeBuildInputs = [ pkgs.gnupg ]; } ''
    mkdir -p $out
    export GNUPGHOME=$(mktemp -d)
    gpg --batch --passphrase "" --quick-generate-key abtest@test rsa2048 sign 0
    keyid=$(gpg --list-keys --with-colons abtest@test | awk -F: '/^pub:/{print $5; exit}')
    test -n "$keyid" || { echo "keygen produced no key" >&2; exit 1; }
    gpg --export                 "$keyid" > $out/pubring.pgp
    gpg --export-secret-keys --armor "$keyid" > $out/priv.asc  # SECRET key (action signs with it)
  '';

  # Second throwaway keypair — the WRONG key for negative signature-verification
  # tests (a manifest signed with this must be rejected by a target carrying
  # testSignKey's pubring).
  testSignKey2 = pkgs.runCommand "abtest-sign-key2" { nativeBuildInputs = [ pkgs.gnupg ]; } ''
    mkdir -p $out
    export GNUPGHOME=$(mktemp -d)
    gpg --batch --passphrase "" --quick-generate-key abtest2@test rsa2048 sign 0
    keyid=$(gpg --list-keys --with-colons abtest2@test | awk -F: '/^pub:/{print $5; exit}')
    test -n "$keyid" || { echo "keygen produced no key" >&2; exit 1; }
    gpg --export                 "$keyid" > $out/pubring.pgp
    gpg --export-secret-keys --armor "$keyid" > $out/priv.asc
  '';

  # Throwaway SSH deploy keypair: the action SSHes to the target as the deploy
  # user to trigger systemd-sysupdate (authorized via mkAppliance's deployKeyPub).
  testDeployKey = pkgs.runCommand "abtest-deploy-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p $out
    ssh-keygen -t ed25519 -N "" -C abtest-deploy -f $out/id_ed25519
    # expose the pub key LINE for the deployUser.authorizedKey option
    cat $out/id_ed25519.pub > $out/pub.line
  '';
  deployKeyPub = builtins.readFile "${testDeployKey}/pub.line";

  # Build an A/B appliance. Thin: heavy A/B config comes from the real nixtache
  # modules. `signVerify` ships the test pubring (Verify=yes). `dataPartition`
  # adds a data mount (T6). `stagingPath` selects local (file://) vs remote
  # (http://) sysupdate source. `deployKey` (path to a private key) authorizes
  # its public half on the target so the action can SSH `systemctl start …`.
  # `extraPackages` lands in the store image (e.g. pkgs.hello in v2 — lets a
  # deploy test prove the update delivered NEW content, not just a new label).
  # `extraModules` appends consumer modules (e.g. the nixos-anywhere install
  # config in ab-anywhere-install.nix layers disko + fileSystems on top).
  mkAppliance =
    { version
    , signVerify ? false
    , dataPartition ? false
    , stagingPath ? "/run/abtest-stage"
    , deployKeyPub ? null
    , storeSize ? "2G"
    , storeFs ? "squashfs"
    , storeCompression ? "zstd"
    , storeCompressionLevel ? null
    , extraPackages ? [ ]
    , extraModules ? [ ]
    }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.deploy-target # runtime: polkit/gating (real nixtache)
        self.nixosModules.ab-image # image build: repart/UKI/sysupdate/verify (real)
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
              inherit stagingPath storeSize storeFs storeCompression storeCompressionLevel;
              extraPartitions = lib.optionalAttrs dataPartition {
                data.repartConfig = {
                  Type = "linux-generic"; Label = "abtest-data"; Format = "ext4";
                  Minimize = "off"; SizeMinBytes = "256M"; SizeMaxBytes = "256M"; SplitName = "-";
                };
              };
              publicKeyFile = lib.mkIf signVerify (lib.mkOverride 90 "${testSignKey}/pubring.pgp");
            };

            services.nixtache.deploy-target = {
              enable = true;
              criticalUnits = lib.optional dataPartition "mnt-data.mount";
              ab.enable = true;
              ab.gating = false;
              # Authorize the deploy key so the action can SSH in + trigger
              # systemd-sysupdate via the module's polkit.
              deployUser = lib.mkIf (deployKeyPub != null) {
                name = "nixos-deploy";
                authorizedKey = deployKeyPub;
                autoProvision = true;
              };
            };

            services.getty.autologinUser = "root";
            users.users.root.initialPassword = "";
            environment.systemPackages = with pkgs; [ util-linux gawk parted ] ++ extraPackages;
            # sshd so the deployer can SSH in + trigger systemd-sysupdate (the
            # deploy user is provisioned by the deploy-target module below).
            services.openssh.enable = true;
            environment.etc."image-version".text = version;
            fileSystems = lib.optionalAttrs dataPartition {
              "/mnt/data" = {
                device = "/dev/disk/by-partlabel/abtest-data";
                fsType = "ext4";
              };
            };
          }
        )
      ] ++ extraModules;
    };
in
{
  inherit pkgs lib testSignKey testSignKey2 testDeployKey deployKeyPub mkAppliance;
}

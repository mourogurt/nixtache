# ab-ota-rollback-vm — boot-counting ROLLBACK: a broken new image exhausts
# its tries and the previously blessed entry boots; the machine stays
# OTA-manageable (a fixed follow-up installs normally).
#
# Tier-0 semantics under test (modules/deploy-target/health-check.nix): a
# failing critical unit keeps boot-complete.target unreached, so the boot is
# never blessed; with boot counting on, each boot of the unblessed entry
# burns a try and, once exhausted, systemd-boot skips the entry and falls
# back to the last blessed one. The test drives the reboots (Tier-0 itself
# never reboots — it only withholds the blessing).
#
# Images: v1 carries a healthy critical service rooted in the persistent upper;
# v2 repairs that service's old-lower dependency into its target upper, runs the
# tool, then deliberately fails criticalUnits (ukiTries=2, healthCheckTimeout=20s).
# Rollback and a later manual older-slot boot must select v1's original upper
# generation and DB without another reconcile. Two physical slots carrying the
# same version with different lower dumps and topology descriptors also retain
# distinct uppers to pin PARTUUID-based selection and generation-owned identity.
# v3 is the fixed follow-up. Needs KVM. Hermetic (deployer LAN only).
{ nixpkgs
, self
, system ? "x86_64-linux"
, appliancePkgs ? import nixpkgs { inherit system; config.contentAddressedByDefault = true; }
}:

let
  otaLib = import ./ab-ota-vm-lib.nix { inherit nixpkgs self system appliancePkgs; };
  inherit (otaLib) fixture pkgs;

  pkgs_1 = pkgs.runCommand "rollback-runtime" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';
  pkgs_2 = pkgs.runCommand "rollback-tool" { } ''
    mkdir -p $out/bin
    printf '#!%s/bin/busybox sh\necho rollback-tool-ok\n' "${pkgs_1}" > $out/bin/tool
    chmod +x $out/bin/tool
  '';
  pkgs_4 = pkgs.runCommand "rollback-slot-marker" { } ''
    mkdir -p $out/bin
    install -m 0755 ${pkgs.busybox}/bin/busybox $out/bin/busybox
  '';
  p1Path = pkgs_1.outPath;
  p2Path = pkgs_2.outPath;
  p2Runtime = builtins.unsafeDiscardStringContext p2Path;
  p4Path = pkgs_4.outPath;

  overlayModules = [
    self.nixosModules.overlay-nix
    ({ lib, ... }: {
      services.nixtache.overlay-nix = {
        enable = true;
        upperOnUpdate = "reconcile";
      };
      services.nixtache.deploy-target.criticalUnits = [ "nixtache-rollback-canary.service" ];
      systemd.services.nixtache-rollback-canary = {
        after = [ "nixtache-overlay-ready.target" ];
        requires = [ "nixtache-overlay-ready.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "${p2Runtime}/bin/tool";
      };
    })
  ];

  # v2's upper-hosted tool starts successfully, then the canary exits nonzero;
  # Tier-0 sees that failure through criticalUnits and withholds the blessing.
  brokenBootModules = [
    ({ lib, ... }: {
      services.nixtache.ab-image.ukiTries = 2;
      services.nixtache.deploy-target.healthCheckTimeout = 20;
      systemd.services.nixtache-rollback-canary = {
        wantedBy = [ "multi-user.target" ];
        script = lib.mkForce ''
          ${p2Runtime}/bin/tool
          echo "nixtache-rollback-canary: failing on purpose (rollback test)"
          exit 1
        '';
      };
    })
  ];

  v1 = otaLib.mkAppliance { version = "1"; extraPackages = [ pkgs_1 pkgs.curl ]; extraModules = overlayModules; };
  v1Image = "${v1.config.system.build.image}/abtest_1.raw";
  sameVersion = otaLib.mkAppliance {
    version = "1";
    extraModules = overlayModules ++ [
      {
        services.nixtache.overlay-nix._layers = [
          {
            id = "same-version-target";
            parent = null;
            upperDir = "/var/lib/nix-overlay/same-version-target/upper";
            workDir = "/var/lib/nix-overlay/same-version-target/work";
            stateDir = "/var/lib/nix-overlay/same-version-target/state";
          }
        ];
      }
    ];
  };
  sameVersionPkg = sameVersion.config.system.build.sysupdate-package;
  sameVersionUkiName = sameVersion.config.system.boot.loader.ukiFile;
  v2 = otaLib.mkAppliance { version = "2"; extraModules = overlayModules ++ brokenBootModules; };
  v2Pkg = v2.config.system.build.sysupdate-package;
  v3 = otaLib.mkAppliance {
    version = "3";
    extraPackages = [ pkgs.hello ];
    extraModules = overlayModules ++ [
      { systemd.services.nixtache-rollback-canary.wantedBy = [ "multi-user.target" ]; }
    ];
  };
  v3Pkg = v3.config.system.build.sysupdate-package;
in
pkgs.testers.runNixOSTest {
  name = "ab-ota-rollback";
  globalTimeout = 5400;

  nodes.deployer = otaLib.deployerNode { extraDependencies = [ pkgs_1 pkgs_2 pkgs_4 sameVersionPkg v2Pkg v3Pkg ]; };

  testScript = ''
    P2 = "${p2Path}"
    P4 = "${p4Path}"

    def create_ab_machine(**kwargs):
        machine = create_machine(start_command="${otaLib.startCommand { image = v1Image; }}", **kwargs)
        driver.machines_qemu.append(machine)
        return machine

    deployer.start()
    deployer.wait_for_unit("nginx.service")
    deployer.wait_for_unit("nix-serve.service")
    deployer.succeed(
      "nix-store --load-db < $(grep -oP '(?<=regInfo=)[^ ]+' /proc/cmdline | sed 's#\\.ro-store/nix/store/#.ro-store/#')"
    )

    appliance = create_ab_machine(name="appliance")
    appliance.start(allow_reboot=True)
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    appliance.wait_until_succeeds("nix --version", timeout=300)
    appliance.succeed("nix-store --realize " + P2, timeout=600)
    appliance.succeed(P2 + "/bin/tool")
    appliance.succeed("ln -sfn " + P2 + " /nix/var/nix/gcroots/rollback-canary")
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${baseNameOf p2Path}")
    appliance.succeed("systemctl start nixtache-rollback-canary.service")
    # v1 must be blessed first: a blessed entry outranks raw tries, so the
    # fallback target after v2's failure is a KNOWN-good boot.
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    v1_slot = appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip()
    v1_selected = appliance.succeed(
      f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
    ).strip()
    v1_db_before = appliance.succeed("sha256sum /nix/var/nix/db/db.sqlite | awk '{print $1}'").strip()
    print("OK: v1 booted and blessed with an upper-hosted critical service")

    # -- Install the broken v2 (tries=2) ------------------------------------
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/abtest && "
      "cp ${v2Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start systemd-sysupdate.service", timeout=900)
    appliance.wait_until_succeeds("sgdisk -p /dev/vda | grep -q nix-store_2", timeout=900)
    appliance.wait_until_succeeds("test -f /boot/EFI/Linux/abtest_2+*.efi", timeout=300)
    print("OK: broken v2 installed to slot B")
    appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
    v2_slot = appliance.succeed("cat /run/nixtache-overlay/prepared-slot").strip()
    v2_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
    v2_target = f"/var/lib/nix-overlay/upper-slots/{v2_slot}/generations/{v2_generation}"
    appliance.succeed(f"grep -q '^policy=reconcile$' {v2_target}/metadata")
    appliance.succeed(f"test -L {v2_target}/host/state/gcroots/rollback-canary")
    appliance.succeed(f"test -d {v2_target}/host/upper/${baseNameOf p1Path}")
    appliance.fail("test -d /var/lib/nix-overlay/upper/${baseNameOf p1Path}")
    print("OK: target-only reconcile preserved the canary root and repaired its old-lower dependency")

    # -- Burn both tries: boot v2 twice, each unblessed ---------------------
    for i in (1, 2):
        appliance.reboot()
        appliance.wait_for_unit("multi-user.target")
        version = appliance.succeed("cat /etc/image-version").strip()
        assert version == "2", f"boot {i}: expected v2 (tries burning), got {version}"
        # The health window (20s) lapses unblessed; the machine keeps running.
        appliance.wait_until_fails(
          "systemctl is-active --quiet nixtache-health-check.service", timeout=120
        )
        appliance.wait_until_succeeds(
          "journalctl -u nixtache-rollback-canary.service -b --no-pager | grep -q 'rollback-tool-ok'",
          timeout=60
        )
        appliance.wait_until_succeeds(
          "journalctl -u nixtache-rollback-canary.service -b --no-pager | grep -q 'failing on purpose'",
          timeout=60
        )
        print(f"OK: v2 boot {i} unblessed (upper tool ran, canary failed, no bless)")

    # -- Tries exhausted → the loader falls back to blessed v1 --------------
    # NOTE: the rolled-back v1 boot does NOT (re)reach boot-complete.target:
    # its entry was blessed on the first boot (the counter became the done
    # form), systemd-bless-boot therefore skips and does not pull the target
    # in. The rollback evidence is the booted version + the exhausted entry.
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    version = appliance.succeed("cat /etc/image-version").strip()
    assert version == "1", f"rollback failed: booted {version}, expected 1"
    # exhausted entries carry the left-done form (+0 or +0-N)
    appliance.succeed("ls /boot/EFI/Linux/abtest_2+0*.efi > /dev/null")
    appliance.succeed("systemctl is-active --quiet sshd.service")
    assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == v1_slot
    assert appliance.succeed(
      f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
    ).strip() == v1_selected, "rollback prepared a replacement for the preserved v1 upper"
    assert appliance.succeed("sha256sum /nix/var/nix/db/db.sqlite | awk '{print $1}'").strip() == v1_db_before, "rollback rewrote the preserved upper DB"
    appliance.succeed("nix path-info " + P2)
    appliance.succeed(P2 + "/bin/tool")
    appliance.succeed("systemctl start nixtache-rollback-canary.service")
    appliance.succeed("systemctl is-active --quiet nixtache-rollback-canary.service")
    print("ROLLBACK OK: exhausted v2 skipped; v1 upper generation, DB and critical service are preserved")

    appliance.succeed("systemctl is-active --quiet sshd.service")
    appliance.succeed("systemctl is-active --quiet systemd-sysupdate.timer")
    appliance.succeed("systemd-sysupdate list > /dev/null")
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_1")
    running_hash = appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1")

    appliance.fail("nixtache-ab-recover 1")
    appliance.succeed(
      "cp /boot/EFI/Linux/abtest_2+0*.efi "
      "/boot/EFI/Linux/abtest_2+0-duplicate.efi"
    )
    appliance.fail("nixtache-ab-recover 2")
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_2")
    appliance.succeed("rm /boot/EFI/Linux/abtest_2+0-duplicate.efi")
    print("OK: recovery refuses the running version and ambiguous artifact deletion")

    appliance.succeed("nixtache-ab-recover 2")
    appliance.fail("sgdisk -p /dev/vda | grep nix-store_2")
    appliance.succeed("sgdisk -p /dev/vda | grep _empty")
    appliance.fail("ls /boot/EFI/Linux/abtest_2+*.efi > /dev/null")
    appliance.fail("ls /boot/EFI/nixtache/abtest_2.lower-db > /dev/null")
    assert appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1") == running_hash
    print("RECOVERY OK: failed v2 removed, inactive slot empty, running v1 preserved")

    deployer.succeed(
      "find /var/lib/nixtache/ab-stage/abtest -mindepth 1 -delete && "
      "cp ${v3Pkg}/* /var/lib/nixtache/ab-stage/abtest/"
    )
    appliance.succeed("systemctl start --wait systemd-sysupdate-update.service", timeout=900)
    appliance.succeed("sgdisk -p /dev/vda | grep nix-store_3")
    appliance.succeed("test -f /boot/EFI/Linux/abtest_3+*.efi")
    assert appliance.succeed("sha256sum /dev/disk/by-partlabel/nix-store_1") == running_hash
    print("OK: fixed v3 installed only into the inactive slot")

    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "3"
    appliance.succeed("hello")
    appliance.wait_until_succeeds(
      "systemctl is-active --quiet boot-complete.target", timeout=300
    )
    print("OK: rollback → explicit recovery → fixed v3 boots and is blessed; running v1 was never overwritten")

    # -- Manual older-slot selection keeps that slot's upper generation ------
    appliance.succeed("mkdir -p /boot/loader/entries")
    appliance.succeed(
      "printf 'title Manual-v1\\nversion 99\\nsort-key abtest\\nuki /EFI/Linux/abtest_1.efi\\n' "
      "> /boot/loader/entries/zz-manual-v1.conf"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == v1_slot
    assert appliance.succeed(
      f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
    ).strip() == v1_selected, "manual older-slot selection cloned or repaired the preserved upper"
    appliance.succeed("nix path-info " + P2)
    appliance.succeed(P2 + "/bin/tool")
    print("MANUAL ROLLBACK OK: the older physical lower selects its own preserved upper and DB")

    # -- Same-version slots retain distinct physical and upper identities ----
    active_device = appliance.succeed(f"readlink -f /dev/disk/by-partuuid/{v1_slot}").strip()
    target_device = appliance.succeed(
      "lsblk -nrpo NAME,PARTUUID,PARTLABEL | "
      f"awk -v active={v1_slot} 'BEGIN{{IGNORECASE=1}} $3 ~ /^nix-store_/ && tolower($2) != active {{print $1; exit}}'"
    ).strip()
    target_slot = appliance.succeed(
      "lsblk -nrpo NAME,PARTUUID,PARTLABEL | "
      f"awk -v active={v1_slot} 'BEGIN{{IGNORECASE=1}} $3 ~ /^nix-store_/ && tolower($2) != active {{print tolower($2); exit}}'"
    ).strip()
    source_lower_sha = appliance.succeed(f"sha256sum {v1_selected}/lower-db | awk '{{print $1}}'").strip()
    source_descriptor_sha = appliance.succeed(f"sha256sum {v1_selected}/overlay-topology.json | awk '{{print $1}}'").strip()
    source_lower_db = appliance.succeed(f"sha256sum {v1_selected}/host/lower-state/db/db.sqlite | awk '{{print $1}}'").strip()
    appliance.succeed("cp /boot/EFI/Linux/abtest_1.efi /root/abtest-source.efi")
    deployer.succeed(
      "mkdir -p /var/lib/nixtache/ab-stage/same-version && "
      "find /var/lib/nixtache/ab-stage/same-version -mindepth 1 -delete && "
      "cp ${sameVersionPkg}/* /var/lib/nixtache/ab-stage/same-version/"
    )
    appliance.succeed(
      f"curl -fsS http://deployer/ab-stage/same-version/abtest_1.nix-store.raw | "
      f"dd of={target_device} bs=4M conv=fsync status=none",
      timeout=900,
    )
    appliance.succeed(
      "curl -fsS http://deployer/ab-stage/same-version/abtest_1.lower-db "
      "> /boot/EFI/nixtache/abtest_1.lower-db"
    )
    appliance.succeed(
      "curl -fsS http://deployer/ab-stage/same-version/abtest_1.overlay-topology.json "
      "> /boot/EFI/nixtache/abtest_1.overlay-topology.json"
    )
    appliance.succeed(
      "curl -fsS http://deployer/ab-stage/same-version/${sameVersionUkiName} "
      "> /root/abtest-target.efi"
    )
    target_lower_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.lower-db | awk '{print $1}'").strip()
    target_descriptor_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.overlay-topology.json | awk '{print $1}'").strip()
    assert target_lower_sha != source_lower_sha, "same-version target lower dump is not distinct"
    assert target_descriptor_sha != source_descriptor_sha, "same-version target topology descriptor is not distinct"
    source_number = active_device.rsplit("vda", 1)[-1]
    target_number = target_device.rsplit("vda", 1)[-1]
    appliance.succeed(f"sgdisk -c {target_number}:nix-store_1 /dev/vda && partprobe /dev/vda && udevadm settle")
    appliance.succeed("systemctl start nixtache-overlay-prepare.service", timeout=900)
    same_target_generation = appliance.succeed("cat /run/nixtache-overlay/prepared-generation").strip()
    same_target = f"/var/lib/nix-overlay/upper-slots/{target_slot}/generations/{same_target_generation}"
    appliance.succeed(f"grep -q '^image_version=1$' {same_target}/metadata")
    appliance.succeed(f"grep -q '^state=ready$' {same_target}/metadata")
    assert appliance.succeed(f"sha256sum {same_target}/lower-db | awk '{{print $1}}'").strip() == target_lower_sha
    assert appliance.succeed(f"sha256sum {same_target}/overlay-topology.json | awk '{{print $1}}'").strip() == target_descriptor_sha
    assert appliance.succeed(f"sha256sum {v1_selected}/lower-db | awk '{{print $1}}'").strip() == source_lower_sha
    assert appliance.succeed(f"sha256sum {v1_selected}/overlay-topology.json | awk '{{print $1}}'").strip() == source_descriptor_sha
    appliance.succeed("nix-store --realize " + P4, timeout=600)
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${baseNameOf p4Path}")
    appliance.fail(f"test -d {same_target}/host/upper/${baseNameOf p4Path}")
    source_db = appliance.succeed("sha256sum /nix/var/nix/db/db.sqlite | awk '{print $1}'").strip()
    same_target_db = appliance.succeed(f"sha256sum {same_target}/host/state/db/db.sqlite | awk '{{print $1}}'").strip()
    print("OK: distinct same-version target artifacts prepared from the unchanged source generation")

    appliance.succeed(
      "cp /root/abtest-source.efi /boot/EFI/Linux/abtest_1.efi && "
      f"sgdisk -c {target_number}:nixtache-hidden-target /dev/vda && "
      "partprobe /dev/vda && udevadm settle"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == v1_slot
    assert appliance.succeed(
      f"readlink -f /var/lib/nix-overlay/upper-slots/{v1_slot}/current"
    ).strip() == v1_selected
    assert appliance.succeed("sha256sum /nix/var/nix/db/db.sqlite | awk '{print $1}'").strip() == source_db
    assert appliance.succeed(f"sha256sum {v1_selected}/host/lower-state/db/db.sqlite | awk '{{print $1}}'").strip() == source_lower_db
    assert appliance.succeed("cat /var/lib/nix-overlay/lower-state/lower-db-sha256").strip() == source_lower_sha
    same_version_log = appliance.succeed(
      "journalctl -b -u nixtache-overlay-select.service -u nixtache-overlay-prepare.service --no-pager -o cat"
    )
    for marker in ("nixtache-overlay: repairing ", "nixtache-overlay: prepared ", "nixtache-overlay: checking "):
        assert marker not in same_version_log, f"same-version rollback ran reverse preparation: {same_version_log}"
    appliance.succeed("nix path-info " + P4)
    appliance.succeed("test -d /var/lib/nix-overlay/upper/${baseNameOf p4Path}")
    out = appliance.succeed(P4 + "/bin/busybox echo source-upper-selected")
    assert "source-upper-selected" in out
    appliance.fail(f"test -d {same_target}/host/upper/${baseNameOf p4Path}")
    appliance.succeed(P2 + "/bin/tool")
    print("OK: forced source boot selected its own generation and DB with P4 present")

    appliance.succeed(
      "cp /root/abtest-target.efi /boot/EFI/Linux/abtest_1.efi && "
      f"sgdisk -c {source_number}:nixtache-hidden-source /dev/vda && "
      f"sgdisk -c {target_number}:nix-store_1 /dev/vda && "
      "partprobe /dev/vda && udevadm settle"
    )
    appliance.reboot()
    appliance.wait_for_unit("multi-user.target")
    assert appliance.succeed("cat /etc/image-version").strip() == "1"
    assert appliance.succeed("cat /run/nixtache-overlay/selected-slot").strip() == target_slot
    assert appliance.succeed(
      f"readlink -f /var/lib/nix-overlay/upper-slots/{target_slot}/current"
    ).strip() == same_target
    assert appliance.succeed("sha256sum /nix/var/nix/db/db.sqlite | awk '{print $1}'").strip() == same_target_db
    assert appliance.succeed("cat /var/lib/nix-overlay/lower-state/lower-db-sha256").strip() == target_lower_sha
    appliance.fail("test -d /var/lib/nix-overlay/upper/${baseNameOf p4Path}")
    out = appliance.succeed(f"nix path-info {P4} 2>&1 || true")
    assert "is not valid" in out, f"same-version target selected the source upper DB ({out!r})"
    appliance.succeed(f"test -d {v1_selected}/host/upper/${baseNameOf p4Path}")
    appliance.succeed(P2 + "/bin/tool")
    print("PASS: forced source/target boots selected distinct same-version generations and DBs")

    shared_uki_sha = appliance.succeed("sha256sum /boot/EFI/Linux/abtest_1.efi | awk '{print $1}'").strip()
    shared_lower_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.lower-db | awk '{print $1}'").strip()
    shared_topology_sha = appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.overlay-topology.json | awk '{print $1}'").strip()
    running_same_version_hash = appliance.succeed(f"sha256sum {target_device}")
    appliance.fail("nixtache-ab-recover 1")
    appliance.fail(f"nixtache-ab-recover 1 {target_slot}")
    appliance.succeed(
      f"sgdisk -c {source_number}:nix-store_1 /dev/vda && "
      "partprobe /dev/vda && udevadm settle"
    )
    appliance.succeed(f"nixtache-ab-recover 1 {v1_slot}")
    appliance.succeed(f"test \"$(lsblk -nrno PARTLABEL {active_device})\" = _empty")
    appliance.succeed(f"test \"$(lsblk -nrno PARTLABEL {target_device})\" = nix-store_1")
    assert appliance.succeed(f"sha256sum {target_device}") == running_same_version_hash
    assert appliance.succeed("sha256sum /boot/EFI/Linux/abtest_1.efi | awk '{print $1}'").strip() == shared_uki_sha
    assert appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.lower-db | awk '{print $1}'").strip() == shared_lower_sha
    assert appliance.succeed("sha256sum /boot/EFI/nixtache/abtest_1.overlay-topology.json | awk '{print $1}'").strip() == shared_topology_sha
    print("SAME-VERSION RECOVERY OK: explicit failed PARTUUID emptied only the inactive slot and preserved shared artifacts")
  '';
}

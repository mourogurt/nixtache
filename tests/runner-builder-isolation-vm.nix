{ nixpkgs, self, system ? "x86_64-linux" }:

let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.testers.runNixOSTest {
  name = "runner-builder-isolation";
  globalTimeout = 1800;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ self.nixosModules.runner ];
    services.nixtache.runner = {
      enable = true;
      forgejoUrl = "http://localhost:3000";
      cache.enable = false;
      instances.default = {
        uuid = "00000000-0000-4000-8000-000000000000";
        tokenFile = toString /dev/null;
      };
      secrets.cachePrivateKey = toString /dev/null;
      store.path = "/srv";
      store.mode = "clone";
      enableSandbox = false;
    };
    containers.runner.config = {
      systemd.services.nix-daemon-storage.serviceConfig.ExecStart = lib.mkForce (
        pkgs.writeShellScript "seed-runner-builder-isolation" ''
          ${lib.getExe pkgs.nix} --extra-experimental-features nix-command copy \
            --no-check-sigs --from daemon --to /srv \
            ${pkgs.nix} ${pkgs.bashInteractive} ${pkgs.coreutils-full}
        ''
      );
    };
  };

  testScript = ''
    import base64
    import json
    import shlex
    import time

    def crun(inner):
        return machine.succeed(
            "nixos-container run runner -- /bin/sh -c " + shlex.quote(inner)
        )

    def derivation_expr(case, side, builder, coreutils_bin):
        shared = "/srv/bincache/runner-isolation/" + case
        if side == "container":
            shared = "/srv/runner-isolation/" + case
        name = "runner-isolation-" + case + "-" + side
        script = (
            "printf '%s %s\\n' \"$$\" \"$UID\" > " + shared + "/ready-" + side + "; "
            + "while [ ! -e " + shared + "/release-" + side + " ]; do sleep 1; done; "
            + "mkdir -p \"$out\"; printf '%s\\n' done > \"$out/done\""
        )
        return (
            "derivation { "
            + "name = " + json.dumps(name) + "; "
            + "system = " + json.dumps("${system}") + "; "
            + "builder = " + json.dumps(builder) + "; "
            + "args = [ \"-c\" " + json.dumps(script) + " ]; "
            + "PATH = " + json.dumps(coreutils_bin) + "; "
            + "}"
        )

    def build_command(side, expr):
        command = (
            "/run/current-system/sw/bin/nix --extra-experimental-features nix-command build "
            "--no-link --print-out-paths --option sandbox false "
            "--option substitute false "
        )
        if side == "container":
            command += "--store unix:///srv/nix/var/nix/daemon-socket/socket "
        return command + "--expr " + shlex.quote(expr)

    def start_build(case, side, expr):
        unit = "runner-isolation-" + case + "-" + side
        script = "/tmp/" + unit + ".sh"
        encoded = base64.b64encode(build_command(side, expr).encode()).decode()
        write = "printf %s " + encoded + " | base64 -d > " + script
        command = "systemd-run --unit=" + unit + " /bin/sh " + script
        if side == "host":
            machine.succeed(write)
            machine.succeed(command)
        else:
            crun(write)
            crun(command)
        return unit

    def wait_for_process_exit(side, pid):
        command = "! kill -0 " + str(pid) + " 2>/dev/null"
        if side == "host":
            machine.wait_until_succeeds(command, timeout=60)
        else:
            machine.wait_until_succeeds(
                "nixos-container run runner -- /bin/sh -c " + shlex.quote(command),
                timeout=60,
            )

    def assert_process_alive(side, pid):
        command = "kill -0 " + str(pid)
        if side == "host":
            machine.succeed(command)
        else:
            crun(command)

    def stop_build(side, unit):
        if side == "host":
            machine.succeed("systemctl stop " + unit)
        else:
            crun("systemctl stop " + unit)

    def wait_for_success(side, unit):
        command = (
            "test \"$(systemctl show -p ActiveState --value " + unit + ")\" = inactive "
            + "&& test \"$(systemctl show -p Result --value " + unit + ")\" = success"
        )
        if side == "host":
            machine.wait_until_succeeds(command, timeout=120)
        else:
            machine.wait_until_succeeds(
                "nixos-container run runner -- /bin/sh -c " + shlex.quote(command),
                timeout=120,
            )

    def assert_output(side, case):
        name = "runner-isolation-" + case + "-" + side
        if side == "host":
            machine.succeed("test -f /nix/store/*-" + name + "/done")
        else:
            crun("test -f /srv/nix/store/*-" + name + "/done")

    def run_cleanup_case(case, cancelled, builder, coreutils_bin):
        peer = "container" if cancelled == "host" else "host"
        shared = "/srv/bincache/runner-isolation/" + case
        machine.succeed("rm -rf " + shared + " && mkdir -p " + shared + " && chmod 777 " + shared)
        units = {
            side: start_build(case, side, derivation_expr(case, side, builder, coreutils_bin))
            for side in ["host", "container"]
        }
        try:
            machine.wait_until_succeeds(
                "test -s " + shared + "/ready-host && test -s " + shared + "/ready-container",
                timeout=120,
            )
        except Exception:
            print("DIAG host builds:", machine.succeed(
                "journalctl -u runner-isolation-" + case + "-host -n 40 --no-pager 2>&1 || true"
            ))
            print("DIAG container builds:", crun(
                "systemctl status nix-daemon-custom runner-isolation-" + case + "-container --no-pager 2>&1 || true; "
                + "journalctl -u nix-daemon-custom -u runner-isolation-" + case + "-container -n 80 --no-pager 2>&1 || true"
            ))
            print("DIAG container pids:", crun(
                "cat /sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.max "
                + "/sys/fs/cgroup/system.slice/nix-daemon-custom.service/pids.current 2>&1 || true; "
                + "ps -eo pid,ppid,uid,stat,comm 2>&1 | tail -40"
            ))
            print("DIAG host container pids:", machine.succeed(
                "cat /sys/fs/cgroup/machine.slice/container@runner.service/pids.max "
                + "/sys/fs/cgroup/machine.slice/container@runner.service/pids.current 2>&1 || true"
            ))
            raise
        ready = {}
        for side in ["host", "container"]:
            fields = machine.succeed("cat " + shared + "/ready-" + side).split()
            ready[side] = {"pid": int(fields[0]), "uid": int(fields[1])}
        assert 30001 <= ready["host"]["uid"] <= 30032, ready
        assert 32001 <= ready["container"]["uid"] <= 32032, ready
        assert ready["host"]["uid"] != ready["container"]["uid"], ready
        stop_build(cancelled, units[cancelled])
        wait_for_process_exit(cancelled, ready[cancelled]["pid"])
        time.sleep(2)
        assert_process_alive(peer, ready[peer]["pid"])
        machine.succeed("touch " + shared + "/release-" + peer)
        wait_for_success(peer, units[peer])
        assert_output(peer, case)
        print("OK: " + cancelled + " cleanup preserved the " + peer + " builder")

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("container@runner.service")
    try:
        machine.wait_until_succeeds(
            "nixos-container run runner -- systemctl is-active nix-daemon-custom",
            timeout=120,
        )
    except Exception:
        print("DIAG startup:", crun(
            "systemctl status nix-daemon-custom nix-daemon-storage --no-pager 2>&1 || true; "
            + "journalctl -u nix-daemon-custom -u nix-daemon-storage -n 100 --no-pager 2>&1 || true"
        ))
        raise
    builder = machine.succeed("readlink -f /bin/sh").strip()
    coreutils_bin = machine.succeed("dirname $(readlink -f $(command -v mkdir))").strip()
    machine.succeed("rm -rf /srv/bincache/runner-isolation && mkdir -p /srv/bincache/runner-isolation")
    run_cleanup_case("host-cancel", "host", builder, coreutils_bin)
    run_cleanup_case("container-cancel", "container", builder, coreutils_bin)
  '';
}

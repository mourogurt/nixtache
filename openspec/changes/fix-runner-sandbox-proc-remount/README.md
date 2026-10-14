# fix-runner-sandbox-proc-remount

Fix the enableSandbox /proc remount: ExecStartPre mounts never reach the daemon's mount namespace (each Exec* gets a fresh ns clone), so nix-daemon runs with nspawn's masked /proc and every daemon-served sandboxed build fails the mountAndPidNamespacesSupported preflight. Wrap each daemon's ExecStart with unshare -m + mount proc + exec instead.

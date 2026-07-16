#!/bin/bash
# Remount the build tmpfs with exec so compiled binaries (Vtb_tarang etc.)
# can run. Codespaces forces noexec on --tmpfs mounts regardless of the
# exec flag in runArgs. Called from entrypoint.sh via sudo.
exec /bin/mount -o remount,exec /workspaces/projects/build

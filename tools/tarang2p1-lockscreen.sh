#!/usr/bin/env bash
# Shown instead of the XFCE session when LICENSE_OK=0 (see entrypoint.sh).
# Nothing else is started behind this — no taskbar, no launcher, no
# terminal — so there is no path from here into a usable desktop. Looping
# on exit means even closing the message window just redraws it instead of
# dropping through to a bare root window.
set -u
export DISPLAY=:1
MSG_FILE="${WORK:-/workspaces/projects/.build.enc}/LICENSE_LOCKED.txt"

xsetroot -solid '#1a1a1a' 2>/dev/null

while true; do
    if [[ -f "$MSG_FILE" ]]; then
        xmessage -center -file "$MSG_FILE" 2>/dev/null
    else
        xmessage -center "No valid license was found for this machine. Contact your instructor/license holder." 2>/dev/null
    fi
    sleep 1
done

#!/usr/bin/env bash
# Linux/Mac equivalent of docker-license-test/client/Get-Fingerprint.ps1 —
# computes the same kind of host-anchored fingerprint (a stable per-machine
# ID, SHA256'd) for use with LICENSE_KEY when running the tarang2p1 image
# via `docker run` on a personal machine (Local Docker Mode).
#
# Must run on the HOST, not inside a container — pass the result in:
#   FP=$(bash tools/get-fingerprint.sh)
#   docker run -e LICENSE_KEY=... -e LICENSE_FINGERPRINT=$FP ... tarang2p1
set -euo pipefail

if [[ "$(uname)" == "Darwin" ]]; then
    RAW="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')"
elif [[ -r /etc/machine-id ]]; then
    RAW="$(cat /etc/machine-id)"
elif [[ -r /var/lib/dbus/machine-id ]]; then
    RAW="$(cat /var/lib/dbus/machine-id)"
else
    echo "Could not find a stable machine identifier on this system." >&2
    exit 1
fi

if [[ -z "$RAW" ]]; then
    echo "Machine identifier was empty." >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$RAW" | sha256sum | cut -d' ' -f1
else
    # macOS has no sha256sum by default
    printf '%s' "$RAW" | shasum -a 256 | cut -d' ' -f1
fi

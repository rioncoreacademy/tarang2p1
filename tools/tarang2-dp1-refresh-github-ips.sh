#!/bin/bash
# Tarang2_dp1 Lab — refresh the egress firewall's GitHub IP allowlist on demand.
#
# entrypoint.sh already does this automatically once at container startup,
# but GitHub's published IP ranges (api.github.com/meta) add/rotate
# individual addresses over time, and the firewall's DROP policy makes a
# stale entry hang silently (no error, just a timeout) rather than fail
# fast. Run this any time `git pull`/`clone`/`push` to GitHub hangs.

set -uo pipefail

echo "[refresh-github] Fetching current GitHub IP ranges from api.github.com/meta..."
GH_META=$(curl -fsSL --max-time 15 https://api.github.com/meta 2>/dev/null)

if [ -z "$GH_META" ]; then
    echo "[refresh-github] ERROR: could not reach api.github.com/meta. Check connectivity." >&2
    exit 1
fi

RANGES=$(echo "$GH_META" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
seen = set()
for key in ("web", "api", "git"):
    for cidr in data.get(key, []):
        if ":" not in cidr and cidr not in seen:   # IPv4 only
            seen.add(cidr)
            print(cidr)
')

if [ -z "$RANGES" ]; then
    echo "[refresh-github] ERROR: could not parse GitHub IP ranges from the response." >&2
    exit 1
fi

count=0
while read -r cidr; do
    sudo iptables -A OUTPUT -p tcp --dport 443 -d "$cidr" -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 22  -d "$cidr" -j ACCEPT
    count=$((count + 1))
done <<< "$RANGES"

echo "[refresh-github] Done — $count GitHub IP ranges allowlisted (ports 443 + 22)."
echo "[refresh-github] Retry your git command now."

#!/usr/bin/env bash
export USER="${USER:-ubuntu}"
export HOME="${HOME:-/home/ubuntu}"

VNC_DEPTH=${VNC_COL_DEPTH:-24}
VNC_PORT=${VNC_PORT:-5901}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PASSWORD=${VNC_PASSWORD:-novnc}
export WORK="${WORK:-/workspaces/projects/.build.enc}"
export BUILD="${BUILD:-/workspaces/projects/build}"

# ── Clone project files FIRST (before firewall blocks GitHub) ────────────────
# Server Mode skips this: BOOTSTRAP_TOKEN means the API will clone the
# student's own fork shortly after startup (see api/main.py _clone_repo()).
if [[ -z "${BOOTSTRAP_TOKEN:-}" && ! -d "$WORK/.git" ]]; then
    echo "[projects] Cloning chipcraft-lab-files -> $WORK …" >> /tmp/lab-crypto.log
    # Clone into a temp dir then merge — cloning directly into $WORK fails
    # when the build tmpfs mount already exists there (git sees non-empty dir).
    TMPCLONE=$(mktemp -d)
    if /usr/bin/git clone https://github.com/rioncoreacademy/chipcraft-lab-files.git "$TMPCLONE" \
        >> /tmp/lab-crypto.log 2>&1; then
        mkdir -p "$WORK"
        shopt -s dotglob
        mv "$TMPCLONE"/* "$WORK"/ 2>>/tmp/lab-crypto.log
        shopt -u dotglob
        rmdir "$TMPCLONE" 2>/dev/null
        echo "[projects] Clone complete." >> /tmp/lab-crypto.log
        # Lock all cloned files read-only — dirs stay writable for gvim/sweep to add .enc files
        find "$WORK" -type f -exec chmod a-w {} \; 2>/dev/null || true
    else
        echo "[projects] WARNING: could not clone chipcraft-lab-files." >> /tmp/lab-crypto.log
        rm -rf "$TMPCLONE"
    fi
fi
# ─────────────────────────────────────────────────────────────────────────────

# ── Egress firewall ──────────────────────────────────────────────────────────
# Block outbound internet so students cannot upload decrypted .v files to
# paste sites, email, or file-sharing services.
# Allows: loopback, internal Docker network (API key), DNS, GitHub (git push).
# Blocks: everything else — HTTP/HTTPS to external sites, SMTP, etc.
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A OUTPUT -d 172.16.0.0/12  -j ACCEPT   # Docker internal
sudo iptables -A OUTPUT -d 10.0.0.0/8     -j ACCEPT   # Docker internal
sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT   # DNS
sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT   # DNS over TCP
# GitHub IP ranges (for git push / git clone). Fetched live from GitHub's own
# meta endpoint — done here, before the DROP policy below is set, so this
# fetch itself isn't blocked. A hardcoded snapshot goes stale: GitHub's
# web/git sections list ~15-30 individual /32 IPs each on top of 4 stable
# CIDR blocks, and those individual IPs rotate — a previous static list here
# was already missing most of the current ones, which silently hangs git
# pull/clone (iptables DROP gives no error, just a hung connection) the
# moment DNS resolves to an IP that isn't whitelisted. Fall back to the 4
# broad, long-lived CIDR blocks alone if the meta fetch fails.
GH_META=$(curl -fsSL --max-time 15 https://api.github.com/meta 2>/dev/null)
if [ -n "$GH_META" ] && echo "$GH_META" | python3 -c '
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
' > /tmp/gh-ranges.txt 2>/dev/null && [ -s /tmp/gh-ranges.txt ]; then
    while read -r cidr; do
        sudo iptables -A OUTPUT -p tcp --dport 443 -d "$cidr" -j ACCEPT
        sudo iptables -A OUTPUT -p tcp --dport 22  -d "$cidr" -j ACCEPT
    done < /tmp/gh-ranges.txt
    echo "GitHub egress allowlist: $(wc -l < /tmp/gh-ranges.txt) ranges fetched live from api.github.com/meta." >> /tmp/lab-crypto.log
else
    echo "WARNING: could not fetch api.github.com/meta — falling back to static GitHub CIDR blocks only." >> /tmp/lab-crypto.log
    sudo iptables -A OUTPUT -p tcp --dport 443 -d 140.82.112.0/20  -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 443 -d 143.55.64.0/20   -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 443 -d 185.199.108.0/22 -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 443 -d 192.30.252.0/22  -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 22  -d 140.82.112.0/20  -j ACCEPT
fi
rm -f /tmp/gh-ranges.txt
# Cloudflare Worker (decryption key fetch) — workers.dev sits behind Cloudflare's
# anycast network, so a single resolved IP is not stable across requests.
# Allow Cloudflare's published IPv4 ranges instead (https://www.cloudflare.com/ips-v4).
for CF_RANGE in \
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
    sudo iptables -A OUTPUT -p tcp --dport 443 -d "$CF_RANGE" -j ACCEPT
done
sudo iptables -P OUTPUT DROP               # block everything else
echo "Egress firewall applied."
# ─────────────────────────────────────────────────────────────────────────────

# ── Fix Codespaces noexec on build tmpfs ─────────────────────────────────────
# Codespaces ignores the exec flag on --tmpfs and mounts build/ with noexec,
# which prevents compiled Verilator binaries (Vtb_tarang) from running.
# Remount with exec so regression tests can execute compiled binaries.
# This is a no-op in local Docker mode where exec is already set.
sudo /usr/local/bin/chipcraft-mount-exec.sh 2>/dev/null || true
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$HOME/.vnc" /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu
touch "$HOME/.Xresources"

# Set xfce4-terminal as the preferred terminal; xterm as fallback.
# Without this, right-click "Open Terminal Here" silently does nothing
# when the desktop environment hasn't auto-detected a terminal emulator.
mkdir -p "$HOME/.config/xfce4"
cat > "$HOME/.config/xfce4/helpers.rc" <<'EOF'
TerminalEmulator=xfce4-terminal
EOF

# Select Adwaita as the active GTK/icon theme. adwaita-icon-theme is
# installed in the image, but a fresh XFCE session doesn't pick it as the
# active theme on its own — xfsettingsd applies whatever xsettings.xml says,
# and with none present toolbar icon lookups (e.g. gvim's) fall through to
# hicolor's near-empty fallback set and render as blank/generic squares.
mkdir -p "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
    <property name="IconThemeName" type="string" value="elementary-xfce"/>
  </property>
</channel>
EOF

# Clean up any leftover lock files from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Start Xvnc with no VNC-level password.
# Security is already enforced at the GitHub OAuth layer before this container starts.
# -SecurityTypes None : no VNC password — websockify (localhost) is the only caller
# -localhost yes      : VNC port is only reachable from inside this container
# -noclipboard        : block clipboard sync between container and browser
Xvnc :1 \
    -depth          "$VNC_DEPTH" \
    -rfbport        "$VNC_PORT" \
    -SecurityTypes  None \
    -localhost      yes \
    -noclipboard \
    &

# Wait for Xvnc to be ready before starting the desktop session
for i in $(seq 1 15); do
    ss -tlnp 2>/dev/null | grep -q "$VNC_PORT" && break
    sleep 1
done

# Start XFCE desktop session on display :1
DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-ubuntu \
    dbus-launch --exit-with-session startxfce4 >> /tmp/xfce.log 2>&1 &

# Wait for VNC to be ready
for i in $(seq 1 15); do
    ss -tlnp 2>/dev/null | grep -q "$VNC_PORT" && break
    sleep 1
done

# Find websockify
WS=""
for candidate in /usr/bin/websockify /usr/local/bin/websockify; do
    [[ -x "$candidate" ]] && WS="$candidate" && break
done
[[ -z "$WS" ]] && WS="python3 -m websockify"

# Start websockify in background
nohup $WS --web=/usr/share/novnc/ "$NOVNC_PORT" localhost:"$VNC_PORT" >> /tmp/novnc.log 2>&1 &

echo "Lab desktop ready on port $NOVNC_PORT"

# Fetch key once and write it to ~/.rbk_state (mode 600). Decryption itself
# happens inside gvim, in memory, when a student opens any *.enc file — no
# plaintext file is ever written to disk (see tools/chipcraft-crypt.vim).
# Logs go to /tmp/lab-crypto.log — visible to root, not ubuntu, for debugging.
# Default CLASS_TOKEN so key fetch works at container start without setup.sh.
export CLASS_TOKEN="${CLASS_TOKEN:-vlsi2026}"
/usr/local/bin/chipcraft-key-init.sh >> /tmp/lab-crypto.log 2>&1 &

# Watch $WORK for stray plaintext appearing by any means other than gvim —
# cp, mv, docker cp, anything. chipcraft-crypt.vim only sees Vim's own
# buffer I/O; this catches what that can't, auto-encrypting and shredding
# any bare plaintext file the instant it shows up. Same log as above.
/usr/local/bin/chipcraft-sweep.sh >> /tmp/lab-crypto.log 2>&1 &

# Decrypt every *.enc under $WORK into $WORK/build once, up front, and
# leave it there for the whole session — DELIBERATE TRADEOFF, see the
# script's own header comment. Waits for the key itself, so this is safe to
# background; in Codespace mode the key isn't available yet at this point
# (CLASS_TOKEN arrives after attach), so setup.sh also calls this again
# once the key is actually ready there.
# Re-refresh the GitHub egress allowlist periodically for the whole
# container lifetime. The one-shot fetch above (before the DROP policy was
# set) only covers the IP ranges GitHub published at container start —
# ranges rotate, and a long-running session (Local Docker Mode especially,
# which has no devcontainer lifecycle hooks to piggyback a refresh on the
# way Codespace mode's setup.sh does) can drift stale over hours. This
# covers every mode (Local Docker, Codespace, Server) uniformly since
# entrypoint.sh is the one script all of them share.
( while true; do
      sleep 1800
      /usr/local/bin/chipcraft-refresh-github >> /tmp/lab-crypto.log 2>&1
  done ) &

/usr/local/bin/chipcraft-decrypt-all.sh >> /tmp/lab-crypto.log 2>&1 &

# Keep container alive
exec tail -f /dev/null

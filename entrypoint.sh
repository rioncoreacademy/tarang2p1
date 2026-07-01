#!/usr/bin/env bash
export USER="${USER:-ubuntu}"
export HOME="${HOME:-/home/ubuntu}"

VNC_GEOMETRY=${VNC_RESOLUTION:-1280x720}
VNC_DEPTH=${VNC_COL_DEPTH:-24}
VNC_PORT=${VNC_PORT:-5901}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PASSWORD=${VNC_PASSWORD:-novnc}

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
# GitHub IP ranges (for git push / git clone)
sudo iptables -A OUTPUT -p tcp --dport 443 -d 140.82.112.0/20  -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 443 -d 185.199.108.0/22 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 443 -d 192.30.252.0/22  -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 22  -d 140.82.112.0/20  -j ACCEPT
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

mkdir -p "$HOME/.vnc" /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu
touch "$HOME/.Xresources"

# Clean up any leftover lock files from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Start Xvnc with no VNC-level password.
# Security is already enforced at the GitHub OAuth layer before this container starts.
# -SecurityTypes None : no VNC password — websockify (localhost) is the only caller
# -localhost yes      : VNC port is only reachable from inside this container
# -noclipboard        : block clipboard sync between container and browser
Xvnc :1 \
    -geometry       "$VNC_GEOMETRY" \
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

# Start Cinnamon desktop session on display :1
DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-ubuntu \
    dbus-launch --exit-with-session cinnamon-session >> /tmp/cinnamon.log 2>&1 &

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

# Clone the public lab-files repo into ~/lab if it isn't there yet — needed
# for Local Docker Mode, where there's no postAttachCommand/setup.sh step to
# do this. Server Mode skips this: BOOTSTRAP_TOKEN being set means the API
# will exec its own `rm -rf ~/lab && git clone <student's fork>` shortly
# after this container starts (see api/main.py's _clone_repo()), so cloning
# the generic public template here would just be wasted work.
if [[ -z "${BOOTSTRAP_TOKEN:-}" && ! -d "$HOME/lab/.git" ]]; then
    echo "[lab] Cloning chipcraft-lab-files -> ~/lab …" >> /tmp/lab-crypto.log
    # Clone into a temp dir, then merge into ~/lab — cloning directly into
    # ~/lab fails because the build tmpfs mount (declared at container
    # creation) already exists there, making git see a "non-empty" target.
    # /usr/bin/git directly — /usr/local/bin/git (the wrapper) blocks `clone` outright.
    TMPCLONE=$(mktemp -d)
    if /usr/bin/git clone https://github.com/narrave/chipcraft-lab-files.git "$TMPCLONE" \
        >> /tmp/lab-crypto.log 2>&1; then
        mkdir -p "$HOME/lab"
        shopt -s dotglob
        mv "$TMPCLONE"/* "$HOME/lab"/ 2>>/tmp/lab-crypto.log
        shopt -u dotglob
        rmdir "$TMPCLONE" 2>/dev/null
    else
        echo "[lab] WARNING: could not clone chipcraft-lab-files." >> /tmp/lab-crypto.log
        rm -rf "$TMPCLONE"
    fi
fi

# Fetch key once and write it to ~/.chipcraft_key (mode 600). Decryption itself
# happens inside gvim, in memory, when a student opens any *.enc file — no
# plaintext file is ever written to disk (see tools/chipcraft-crypt.vim).
# Logs go to /tmp/lab-crypto.log — visible to root, not ubuntu, for debugging.
/usr/local/bin/chipcraft-key-init.sh >> /tmp/lab-crypto.log 2>&1 &

# Watch ~/lab for stray plaintext appearing by any means other than gvim —
# cp, mv, docker cp, anything. chipcraft-crypt.vim only sees Vim's own
# buffer I/O; this catches what that can't, auto-encrypting and shredding
# any bare plaintext file the instant it shows up. Same log as above.
/usr/local/bin/chipcraft-sweep.sh >> /tmp/lab-crypto.log 2>&1 &

# Decrypt every *.enc under ~/lab into ~/lab/build once, up front, and
# leave it there for the whole session — DELIBERATE TRADEOFF, see the
# script's own header comment. Waits for the key itself, so this is safe to
# background; in Codespace mode the key isn't available yet at this point
# (CLASS_TOKEN arrives after attach), so setup.sh also calls this again
# once the key is actually ready there.
/usr/local/bin/chipcraft-decrypt-all.sh >> /tmp/lab-crypto.log 2>&1 &

# Keep container alive
exec tail -f /dev/null

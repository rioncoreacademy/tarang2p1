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
sudo iptables -P OUTPUT DROP               # block everything else
echo "Egress firewall applied."
# ─────────────────────────────────────────────────────────────────────────────

# Kill any leftover VNC lock from a previous run
vncserver -kill :1 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

mkdir -p "$HOME/.vnc" /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu
touch "$HOME/.Xresources"

printf '%s' "$VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources" 2>/dev/null
exec dbus-launch --exit-with-session startxfce4
EOF
chmod +x "$HOME/.vnc/xstartup"

# Start VNC — NeverShared + no clipboard sync to/from noVNC client
vncserver :1 -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" -rfbport "$VNC_PORT" \
    -noclipboard

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

# Fetch key from API, decrypt .v.enc → tmpfs (/home/ubuntu/labs), re-encrypt on save.
# Logs go to /tmp/lab-crypto.log — visible to root, not ubuntu, for debugging.
nohup /usr/local/bin/decrypt_watch.sh >> /tmp/lab-crypto.log 2>&1 &

# Keep container alive
exec tail -f /dev/null

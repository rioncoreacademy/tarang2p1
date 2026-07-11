#!/bin/bash
export USER="${USER:-ubuntu}"
export HOME="${HOME:-/home/ubuntu}"

# Kill any leftover VNC from previous session
vncserver -kill :1 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

mkdir -p "$HOME/.vnc" /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu
touch "$HOME/.Xresources"

# Set VNC password
printf 'novnc' | vncpasswd -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

# Write xstartup — dbus-launch ensures XFCE4 desktop loads properly
cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources" 2>/dev/null
exec dbus-launch --exit-with-session startxfce4
EOF
chmod +x "$HOME/.vnc/xstartup"

# Start VNC server
vncserver :1 -geometry 1280x720 -depth 24 -rfbport 5901

# Wait until VNC port is ready (up to 15 seconds)
for i in $(seq 1 15); do
    ss -tlnp 2>/dev/null | grep -q 5901 && break
    sleep 1
done

# xfdesktop's backdrop properties are keyed by the actual RandR-detected
# monitor name (confirmed to be "monitorVNC-0" for TigerVNC, not "monitor0"
# — and it registers separate entries per workspace, e.g. workspace0..3).
# The xfce4-desktop.xml this container's entrypoint.sh seeds only covers the
# "monitor0" fallback case. A single "wait for any property to exist" check
# is NOT enough: our own seeded "monitor0" entries already exist at t=0, so
# that condition would be satisfied immediately, before xfdesktop has even
# registered its real "monitorVNC-0" entries — re-scan and re-apply
# repeatedly instead so whatever shows up late still gets caught.
(
    export DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
    for i in $(seq 1 20); do
        sleep 2
        props="$(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null)"
        [[ -z "$props" ]] && continue
        while read -r p; do
            case "$p" in
                */last-image)  xfconf-query -c xfce4-desktop -p "$p" -s /usr/share/backgrounds/tarang2p1-background.png ;;
                */image-style) xfconf-query -c xfce4-desktop -p "$p" -s 4 ;;
            esac
        done <<< "$props"
    done
) >> /tmp/xfce.log 2>&1 &

# Find websockify
WS=""
for candidate in /usr/bin/websockify /usr/local/bin/websockify $(which websockify 2>/dev/null); do
    [[ -x "$candidate" ]] && WS="$candidate" && break
done
[[ -z "$WS" ]] && WS="python3 -m websockify"

# Start websockify and detach fully from this shell
nohup $WS --web=/usr/share/novnc/ 6080 localhost:5901 >> /tmp/novnc.log 2>&1 &
disown

echo "Desktop ready — open port 6080 in the Ports tab"

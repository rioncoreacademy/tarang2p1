#!/usr/bin/env bash
set -euo pipefail

export USER=ubuntu
export HOME=/home/ubuntu

VNC_GEOMETRY=${VNC_RESOLUTION:-1280x720}
VNC_DEPTH=${VNC_COL_DEPTH:-24}
VNC_PORT=${VNC_PORT:-5901}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PASSWORD=${VNC_PASSWORD:-novnc}

mkdir -p "$HOME/.vnc"
mkdir -p /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu
touch "$HOME/.Xresources"

if [[ ! -f "$HOME/.vnc/passwd" ]]; then
  # TightVNC requires a password; use VNC_PASSWORD env or default.
  vncpasswd -f <<< "$VNC_PASSWORD" > "$HOME/.vnc/passwd"
  chmod 600 "$HOME/.vnc/passwd"
fi

cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=/tmp/runtime-ubuntu
xrdb $HOME/.Xresources
startxfce4 &
sleep 2
xfce4-terminal &
EOF
chmod +x "$HOME/.vnc/xstartup"

# Start VNC server
vncserver :1 -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" -rfbport "$VNC_PORT"

# Start noVNC
websockify --web=/usr/share/novnc/ "$NOVNC_PORT" localhost:"$VNC_PORT"

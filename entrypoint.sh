#!/usr/bin/env bash
export USER="${USER:-ubuntu}"
export HOME="${HOME:-/home/ubuntu}"

VNC_DEPTH=${VNC_COL_DEPTH:-24}
VNC_PORT=${VNC_PORT:-5901}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PASSWORD=${VNC_PASSWORD:-novnc}
export WORK="${WORK:-/workspaces/projects/.build.enc}"
export BUILD="${BUILD:-/workspaces/projects/build}"

# ── License gate ──────────────────────────────────────────────────────────
# Tier 1: no key at all -> the image itself refuses to run. Only applies
# when LICENSE_API_BASE_URL is actually configured for this build/deployment
# — unset (the default) skips both tiers and behaves as before.
if [[ -n "${LICENSE_API_BASE_URL:-}" && -z "${LICENSE_KEY:-}" ]]; then
    echo "[license] LICENSE_KEY not set — this image requires a license. Exiting." >&2
    exit 1
fi

# Tier 2: key present but invalid for THIS machine (wrong/shared
# fingerprint, expired, revoked, seat already used elsewhere) -> the
# desktop still boots so the person can see why, but the project folder
# itself stays locked instead of being populated.
#
# Local Docker Mode (Tarang2p1.exe) is distinguished from Server Mode by
# BOOTSTRAP_TOKEN: Server Mode sets LICENSE_API_BASE_URL/LICENSE_KEY too
# (one shared license for the whole deployment, see api/main.py) but
# delivers the Verilog decryption key its own way (BOOTSTRAP_TOKEN ->
# /lab-key), not through this license check. Only Local Docker Mode's own
# license (no BOOTSTRAP_TOKEN) gets its decryption key from THIS call --
# see the key-delivery block near the bottom of this file.
LICENSE_OK=1
LICENSE_ENCRYPTION_KEY=""
# A product can now bundle multiple folders (all sharing the one
# encryption_key above) -- see docker-license-test's product_folders table.
LICENSE_PRODUCT_FOLDERS=()
# Machine-readable reason the lock screen/LICENSE_LOCKED.txt map to a
# specific human message below -- see the case statement in the "Clone
# project files" block. Matches the license API's own `error` values
# (license_expired, license_revoked, etc.) plus a few local-only reasons.
LICENSE_ERROR_REASON=""
IS_LOCAL_DOCKER_LICENSE_PATH=0
[[ -n "${LICENSE_API_BASE_URL:-}" && -z "${BOOTSTRAP_TOKEN:-}" ]] && IS_LOCAL_DOCKER_LICENSE_PATH=1

_extract_error() {
    # $1 = raw JSON response from tarang2p1-license-check.py
    printf '%s' "$1" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("error", "unreachable"))'
}

if [[ -n "${LICENSE_API_BASE_URL:-}" ]]; then
    if [[ -z "${LICENSE_FINGERPRINT:-}" ]]; then
        LICENSE_OK=0
        LICENSE_ERROR_REASON="no_fingerprint"
    else
        ACT_OUT=$(python3 /usr/local/bin/tarang2p1-license-check.py activate "$LICENSE_KEY" "$LICENSE_FINGERPRINT" 2>>/tmp/lab-crypto.log)
        ACT_RC=$?
        VAL_OUT=$(python3 /usr/local/bin/tarang2p1-license-check.py validate "$LICENSE_KEY" "$LICENSE_FINGERPRINT" 2>>/tmp/lab-crypto.log)
        VAL_RC=$?
        printf '%s\n%s\n' "$ACT_OUT" "$VAL_OUT" >> /tmp/lab-crypto.log
        if [[ $ACT_RC -ne 0 ]]; then
            LICENSE_OK=0
            LICENSE_ERROR_REASON=$(_extract_error "$ACT_OUT")
        elif [[ $VAL_RC -ne 0 ]]; then
            LICENSE_OK=0
            LICENSE_ERROR_REASON=$(_extract_error "$VAL_OUT")
        else
            # validate's response now also carries encryption_key/product_folders
            # (see docker-license-test's LicenseController::resolveProductFields) --
            # parse them out of the same call instead of a separate request.
            # Line 1 = encryption_key, remaining lines (if any) = folder paths.
            mapfile -t _LICENSE_RESP_LINES < <(printf '%s' "$VAL_OUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("encryption_key", ""))
for f in d.get("product_folders", []):
    print(f)')
            LICENSE_ENCRYPTION_KEY="${_LICENSE_RESP_LINES[0]:-}"
            LICENSE_PRODUCT_FOLDERS=("${_LICENSE_RESP_LINES[@]:1}")
        fi
    fi
fi

# Fail closed, not open: a "valid" license with no key (misconfigured
# DEFAULT_ENCRYPTION_KEY server-side) must lock the folder, not silently
# proceed with no decryption key at all.
if [[ "$IS_LOCAL_DOCKER_LICENSE_PATH" == "1" && "$LICENSE_OK" == "1" && -z "$LICENSE_ENCRYPTION_KEY" ]]; then
    LICENSE_OK=0
    LICENSE_ERROR_REASON="no_encryption_key"
    echo "[license] WARNING: license valid but API returned no encryption_key — locking as a safety measure." >> /tmp/lab-crypto.log
fi
export LICENSE_OK
# ─────────────────────────────────────────────────────────────────────────────

# ── Clone project files FIRST (before firewall blocks GitHub) ────────────────
# Server Mode skips this: BOOTSTRAP_TOKEN means the API will clone the
# student's own fork shortly after startup (see api/main.py _clone_repo()).
if [[ "$LICENSE_OK" != "1" ]]; then
    mkdir -p "$WORK"
    # Explicit line breaks (~60 cols) rather than one long line -- xmessage
    # (tarang2p1-lockscreen.sh) doesn't auto-wrap, so a single long line just
    # runs off the edge of the message box instead of wrapping.
    case "$LICENSE_ERROR_REASON" in
        license_expired)
            LOCK_REASON_MSG=$'This project folder is locked: your license has\nexpired. Contact RionCore Academy support to renew.' ;;
        license_revoked)
            LOCK_REASON_MSG=$'This project folder is locked: this license has\nbeen revoked. Contact RionCore Academy support.' ;;
        license_not_found)
            LOCK_REASON_MSG=$'This project folder is locked: no license was\nfound with this key. Contact RionCore Academy\nsupport.' ;;
        machine_not_activated|activation_limit_reached)
            LOCK_REASON_MSG=$'This project folder is locked: this license is\nalready activated on a different machine - each\nkey only works on one. Contact RionCore Academy\nsupport.' ;;
        no_fingerprint)
            LOCK_REASON_MSG=$'This project folder is locked: this machine\'s\nfingerprint could not be determined. Contact\nRionCore Academy support.' ;;
        no_encryption_key)
            LOCK_REASON_MSG=$'This project folder is locked: your license is\nvalid, but the lab content could not be prepared\nright now. Contact RionCore Academy support.' ;;
        unreachable*)
            LOCK_REASON_MSG=$'This project folder is locked: could not reach\nthe license server to verify this license. Check\nyour internet connection, or contact RionCore\nAcademy support if this continues.' ;;
        *)
            LOCK_REASON_MSG=$'This project folder is locked: no valid license\nwas found for this machine. Contact RionCore\nAcademy support.' ;;
    esac
    printf '%s\n' "$LOCK_REASON_MSG" > "$WORK/LICENSE_LOCKED.txt"
    chmod 555 "$WORK"
    echo "[license] Project folder locked (reason: ${LICENSE_ERROR_REASON:-unknown}) — no valid license for this machine." >> /tmp/lab-crypto.log
elif [[ -z "${BOOTSTRAP_TOKEN:-}" && ${#LICENSE_PRODUCT_FOLDERS[@]} -gt 0 && ! -d "$WORK/.git" ]]; then
    # Local Docker Mode license scoped to one or more product folders —
    # sparse-checkout just those subtrees (+ mywork/) instead of the whole
    # repo. A plain `mv` of just the subfolders would discard .git (it lives
    # at the clone root), breaking the documented `git add/commit/push`
    # workflow — sparse-checkout keeps a real working tree while still only
    # fetching the scoped content. --cone mode keeps root-level infra files
    # (Makefile, .gitignore) present automatically alongside whatever's
    # listed in `sparse-checkout set`. `git sparse-checkout set` natively
    # accepts multiple paths, so bundled-folder products need no extra logic
    # here beyond passing the whole array.
    echo "[projects] Cloning tarang2p1-files -> $WORK (scoped to: ${LICENSE_PRODUCT_FOLDERS[*]}) …" >> /tmp/lab-crypto.log
    TMPCLONE=$(mktemp -d)
    if /usr/bin/git clone --no-checkout https://github.com/rioncoreacademy/tarang2p1-files.git "$TMPCLONE" \
            >> /tmp/lab-crypto.log 2>&1 \
        && ( cd "$TMPCLONE" \
             && git sparse-checkout init --cone \
             && git sparse-checkout set "${LICENSE_PRODUCT_FOLDERS[@]}" mywork \
             && git checkout ) >> /tmp/lab-crypto.log 2>&1; then
        MISSING_FOLDERS=()
        for _f in "${LICENSE_PRODUCT_FOLDERS[@]}"; do
            [[ -d "$TMPCLONE/$_f" ]] || MISSING_FOLDERS+=("$_f")
        done
        if [[ ${#MISSING_FOLDERS[@]} -eq 0 ]]; then
            mkdir -p "$WORK"
            shopt -s dotglob
            mv "$TMPCLONE"/* "$WORK"/ 2>>/tmp/lab-crypto.log
            shopt -u dotglob
            rmdir "$TMPCLONE" 2>/dev/null
            echo "[projects] Clone complete (scoped to: ${LICENSE_PRODUCT_FOLDERS[*]})." >> /tmp/lab-crypto.log
            find "$WORK" -type f -exec chmod a-w {} \; 2>/dev/null || true
        else
            rm -rf "$TMPCLONE"
            mkdir -p "$WORK"
            cat > "$WORK/LICENSE_LOCKED.txt" <<EOF
This license is scoped to project folder(s) that could not be found in the
lab content repository: ${MISSING_FOLDERS[*]}. Contact RionCore Academy
support - this is a content configuration issue, not a problem with your
license itself.
EOF
            chmod 555 "$WORK"
            echo "[projects] WARNING: product folder(s) not found in repo: ${MISSING_FOLDERS[*]} — locked." >> /tmp/lab-crypto.log
        fi
    else
        echo "[projects] WARNING: could not clone/sparse-checkout tarang2p1-files." >> /tmp/lab-crypto.log
        rm -rf "$TMPCLONE"
    fi
elif [[ -z "${BOOTSTRAP_TOKEN:-}" && ! -d "$WORK/.git" ]]; then
    echo "[projects] Cloning tarang2p1-files -> $WORK …" >> /tmp/lab-crypto.log
    # Clone into a temp dir then merge — cloning directly into $WORK fails
    # when the build tmpfs mount already exists there (git sees non-empty dir).
    TMPCLONE=$(mktemp -d)
    if /usr/bin/git clone https://github.com/rioncoreacademy/tarang2p1-files.git "$TMPCLONE" \
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
        echo "[projects] WARNING: could not clone tarang2p1-files." >> /tmp/lab-crypto.log
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
sudo /usr/local/bin/tarang2p1-mount-exec.sh 2>/dev/null || true
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

# Default desktop wallpaper (RionCore Academy branding, baked into the image
# at /usr/share/backgrounds/tarang2p1-background.png). Seeds the common
# "monitor0" property path so it's already correct the moment xfdesktop
# starts; the runtime xfconf-query pass further below covers whatever
# monitor name Xvnc's RandR output actually gets detected as, in case it
# differs from "monitor0".
cat > "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/tarang2p1-background.png"/>
          <property name="image-style" type="int" value="4"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

# Clean up any leftover lock files from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Start Xvnc with no VNC-level password.
# Security is enforced by the license gate above (Server Mode additionally
# gates container creation itself before this container ever starts).
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

# Start the desktop session on display :1 — only a real XFCE session when
# the license gate above passed. An invalid/missing license still gets a
# VNC connection (so the person can see why), but no desktop: no taskbar,
# no launcher, no terminal, just the lock message from tarang2p1-lockscreen.sh
# looping in front of a bare root window. This is what actually keeps a
# locked-out machine out, on top of the project-folder lock above.
if [[ "$LICENSE_OK" == "1" ]]; then
    DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-ubuntu \
        dbus-launch --exit-with-session startxfce4 >> /tmp/xfce.log 2>&1 &
else
    DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-ubuntu \
        /usr/local/bin/tarang2p1-lockscreen.sh >> /tmp/xfce.log 2>&1 &
fi

# xfdesktop's backdrop properties are keyed by the actual RandR-detected
# monitor name (confirmed to be "monitorVNC-0" for TigerVNC, not "monitor0"
# — and it registers separate entries per workspace, e.g. workspace0..3).
# The xfce4-desktop.xml seed above only covers the "monitor0" fallback case.
# A single "wait for any property to exist" check is NOT enough here: our
# own seeded "monitor0" entries already exist at t=0, so that condition
# would be satisfied immediately, before xfdesktop has even registered its
# real "monitorVNC-0" entries — re-scan and re-apply repeatedly instead so
# whatever shows up late (or on more workspaces) still gets caught.
# Skipped entirely when locked out — xfdesktop isn't running, so there are
# no backdrop properties to ever find.
if [[ "$LICENSE_OK" == "1" ]]; then
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
fi

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

echo "Desktop ready on port $NOVNC_PORT"

# Everything below populates/decrypts lab content — skip entirely when the
# license gate above locked $WORK, so a locked-out machine never fetches
# CHIPCRAFT_KEY or decrypts anything into $BUILD either. The folder lock is
# real, not cosmetic.
if [[ "$LICENSE_OK" == "1" ]]; then

# Fetch key once and write it to ~/.rbk_state (mode 600). Decryption itself
# happens inside gvim, in memory, when a student opens any *.enc file — no
# plaintext file is ever written to disk (see tools/tarang2p1-crypt.vim).
# Logs go to /tmp/lab-crypto.log — visible to root, not ubuntu, for debugging.
#
# Local Docker Mode license (no BOOTSTRAP_TOKEN) already got its key from
# the license API's activate/validate response above — write it straight to
# ~/.rbk_state and skip tarang2p1-key-init.sh (and CLASS_TOKEN/Cloudflare)
# entirely for this path. Every other mode (Codespace, Server, dev) is
# unaffected — key-init.sh runs exactly as it always has, CLASS_TOKEN still
# defaults to vlsi2026 for Codespace Mode's Cloudflare Worker fetch.
if [[ "$IS_LOCAL_DOCKER_LICENSE_PATH" == "1" ]]; then
    umask 077
    printf '%s\n' "$LICENSE_ENCRYPTION_KEY" > "$HOME/.rbk_state"
    chmod 600 "$HOME/.rbk_state"
    echo "[license] Decryption key delivered via license API (product_folders='${LICENSE_PRODUCT_FOLDERS[*]}')." >> /tmp/lab-crypto.log
else
    export CLASS_TOKEN="${CLASS_TOKEN:-vlsi2026}"
    /usr/local/bin/tarang2p1-key-init.sh >> /tmp/lab-crypto.log 2>&1 &
fi
unset LICENSE_ENCRYPTION_KEY

# Watch $WORK for stray plaintext appearing by any means other than gvim —
# cp, mv, docker cp, anything. tarang2p1-crypt.vim only sees Vim's own
# buffer I/O; this catches what that can't, auto-encrypting and shredding
# any bare plaintext file the instant it shows up. Same log as above.
/usr/local/bin/tarang2p1-sweep.sh >> /tmp/lab-crypto.log 2>&1 &

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
      sudo /usr/local/bin/tarang2p1-refresh-github >> /tmp/lab-crypto.log 2>&1
  done ) &

/usr/local/bin/tarang2p1-decrypt-all.sh >> /tmp/lab-crypto.log 2>&1 &

fi
# ─────────────────────────────────────────────────────────────────────────────

# Keep container alive
exec tail -f /dev/null

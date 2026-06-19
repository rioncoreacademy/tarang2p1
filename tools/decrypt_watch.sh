#!/bin/bash
# Transparent encrypt/decrypt for .v lab files inside the container.
#
# Security model
# ──────────────
# 1. The key never lives in this image.  It is fetched at startup from the API
#    container over the internal Docker network using a one-time BOOTSTRAP_TOKEN
#    that expires in 30 seconds.
# 2. After the key is obtained the token is erased from the environment so
#    students cannot reuse it via a terminal.
# 3. Decrypted .v files are written to /home/ubuntu/labs which is a tmpfs
#    (RAM-only mount).  Plaintext never touches disk.
# 4. Whenever the student saves a .v file it is immediately re-encrypted back
#    to /home/ubuntu/work/*.v.enc (the persistent volume).
#
# Environment variables (set by the API when launching the container):
#   BOOTSTRAP_TOKEN   – one-time token exchanged for the key
#   API_INTERNAL_URL  – base URL of the API on the internal Docker network
#                       (default: http://api:8000)
#   LAB_DIR           – where decrypted .v files are written (default: /home/ubuntu/labs, tmpfs)
#   WORK_DIR          – persistent volume with .v.enc sources  (default: /home/ubuntu/work)

set -euo pipefail

API_URL="${API_INTERNAL_URL:-http://api:8000}"
LAB_DIR="${LAB_DIR:-/home/ubuntu/labs}"    # tmpfs — decrypted .v files (RAM only)
WORK_DIR="${WORK_DIR:-/home/ubuntu/lab}"   # git-cloned repo — source .v.enc files live here

# ── 1. Obtain the key via one-time bootstrap token ───────────────────────────

_fetch_key() {
    local token="$1"
    local response
    response=$(curl -sf --max-time 10 \
        -X POST "$API_URL/lab-key" \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"$token\"}" 2>/dev/null) || return 1
    # Extract the "key" field from {"key":"..."} without jq dependency
    echo "$response" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['key'])" 2>/dev/null
}

KEY=""

if [[ -n "${BOOTSTRAP_TOKEN:-}" ]]; then
    echo "[lab] Fetching key from API …"
    KEY=$(_fetch_key "$BOOTSTRAP_TOKEN") || true

    # Erase the token from this process's environment immediately.
    # After this point 'env' inside the container will not show the token.
    unset BOOTSTRAP_TOKEN
    export BOOTSTRAP_TOKEN=""
fi

# Allow a plaintext LAB_KEY env var as a fallback for local development/testing
# (never set this in production — it defeats the purpose).
if [[ -z "$KEY" && -n "${LAB_KEY:-}" ]]; then
    echo "[lab] WARNING: using LAB_KEY env var (not recommended in production)" >&2
    KEY="$LAB_KEY"
fi

if [[ -z "$KEY" ]]; then
    echo "[lab] ERROR: could not obtain decryption key. Check BOOTSTRAP_TOKEN and API connectivity." >&2
    exit 1
fi

echo "[lab] Key obtained."

# ── 2. Helper functions ───────────────────────────────────────────────────────

decrypt_file() {
    local enc="$1"
    local base
    base=$(basename "$enc" .enc)         # counter.v.enc → counter.v
    local out="$LAB_DIR/$base"
    if openssl enc -d -aes-256-cbc -pbkdf2 \
           -k "$KEY" -in "$enc" -out "$out" 2>/dev/null; then
        local student="${GITHUB_USER:-unknown}"

        # ── Invisible watermark (primary) ────────────────────────────────────
        # Encodes the student's GitHub username as trailing spaces on each line.
        # Completely invisible to the human eye and to editors.
        # Survives deletion of the visible comment below.
        python3 /usr/local/bin/watermark.py encode "$student" \
            < "$out" > "${out}.wm" && mv "${out}.wm" "$out"

        # ── Visible watermark (decoy) ─────────────────────────────────────────
        # Student will likely delete this line thinking it removes the watermark.
        # The invisible one above is still there even after they delete this.
        local stamp="// [ChipCraft] Student: @${student} | $(date -u +%Y-%m-%d)"
        printf '%s\n' "$stamp" | cat - "$out" > "${out}.hdr" && mv "${out}.hdr" "$out"

        echo "[lab] Decrypted : $base"
    else
        echo "[lab] ERROR – could not decrypt: $(basename "$enc")" >&2
    fi
}

encrypt_file() {
    local v_file="$1"
    local base
    base=$(basename "$v_file")           # counter.v
    local enc="$WORK_DIR/${base}.enc"

    # Only re-encrypt teacher-provided files — those that already have a
    # .v.enc source in WORK_DIR.  New files created by the student (no
    # matching .enc) are left alone as plain .v files.
    if [[ ! -f "$enc" ]]; then
        echo "[lab] Skipped  : $base (student file — no .enc source)"
        return 0
    fi

    # Atomic write: encrypt to tmp then rename so a kill mid-save can't corrupt.
    local tmp
    tmp=$(mktemp "$enc.XXXXXX")
    if openssl enc -aes-256-cbc -pbkdf2 -salt \
           -k "$KEY" -in "$v_file" -out "$tmp" 2>/dev/null; then
        mv "$tmp" "$enc"
        echo "[lab] Re-encrypted: $base → work/${base}.enc"
    else
        rm -f "$tmp"
        echo "[lab] ERROR – could not re-encrypt: $base" >&2
    fi
}

# ── 3. Initial decryption (git repo → tmpfs) ─────────────────────────────────

mkdir -p "$LAB_DIR" "$WORK_DIR"
echo "[lab] Decrypting lab files …"
found=0

while IFS= read -r enc; do
    decrypt_file "$enc"
    found=1
done < <(find "$WORK_DIR" -maxdepth 1 -name "*.v.enc" 2>/dev/null)

# Fall back to the read-only shared folder if the git repo is empty
if [[ $found -eq 0 ]]; then
    while IFS= read -r enc; do
        decrypt_file "$enc"
        found=1
    done < <(find /home/ubuntu/shared -maxdepth 5 -name "*.v.enc" 2>/dev/null)
fi

[[ $found -eq 0 ]] && echo "[lab] No *.v.enc source files found."

# Copy plain support files (Makefile, *.cpp, *.sh, etc.) from the git repo
# into the working labs dir so students can 'make' right there.
echo "[lab] Copying support files → $LAB_DIR"
find "$WORK_DIR" -maxdepth 1 -type f \
    ! -name "*.v" ! -name "*.v.enc" ! -name ".gitignore" \
    | while IFS= read -r f; do
        cp -n "$f" "$LAB_DIR/"   # -n: don't overwrite if already there
        echo "[lab] Copied : $(basename "$f")"
    done

# Block git inside LAB_DIR (tmpfs) so students cannot push decrypted .v files.
# The git repo lives in WORK_DIR (~/lab) which only has .v.enc files.
rm -rf "$LAB_DIR/.git"
cat > "$LAB_DIR/.gitignore" << 'GIEOF'
# Git is disabled in this directory — work with ~/lab for version control
*.v
GIEOF

echo "[lab] Watching $LAB_DIR for student saves …"

# ── 4. Watch for saves and re-encrypt ────────────────────────────────────────
# Watch the entire home directory recursively so students can save .v files
# from any folder (~/labs/, ~/work/, ~/, etc.).
# encrypt_file checks for a matching .v.enc in WORK_DIR before acting,
# so student-created files and files in unrelated folders are silently skipped.
#
# close_write : mousepad, gedit, nano, …
# moved_to    : vim's atomic save (write-to-temp → rename)
inotifywait -m -r \
    -e close_write,moved_to \
    --format '%w%f' \
    "$HOME" 2>/dev/null \
| while IFS= read -r changed; do
    # Only act on .v files (not .v.enc, not .vcd, not anything else)
    if [[ "$changed" == *.v && ! "$changed" == *.v.enc ]]; then
        encrypt_file "$changed"
    fi
done

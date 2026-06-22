#!/bin/bash
# Transparent encrypt/decrypt for ALL lab files inside the container.
#
# Security model
# ──────────────
# 1. The key never lives in this image.  It is fetched at startup from the API
#    container over the internal Docker network using a one-time BOOTSTRAP_TOKEN
#    that expires in 30 seconds.
# 2. After the key is obtained the token is erased from the environment so
#    students cannot reuse it via a terminal.
# 3. Decrypted files are written to /home/ubuntu/labs which is a tmpfs
#    (RAM-only mount).  Plaintext never touches disk.
# 4. Whenever the student saves any file it is immediately re-encrypted back
#    to the corresponding path in /home/ubuntu/lab/*.enc (the persistent volume).
# 5. Subfolder structure is preserved: lab/sub/file.enc → labs/sub/file
#
# Environment variables:
#   BOOTSTRAP_TOKEN   – one-time token (server mode via NVR API)
#   API_INTERNAL_URL  – NVR API URL (default: http://api:8000)
#   CLASS_TOKEN       – Cloudflare Worker class token (local Docker mode)
#   CHIPCRAFT_KEY     – direct key (Codespace mode)
#   LAB_DIR           – decrypted files destination (default: /home/ubuntu/labs)
#   WORK_DIR          – encrypted source files (default: /home/ubuntu/lab)
#   SOURCE_SUBDIR     – subfolder inside WORK_DIR that holds .enc files (e.g. "labs")
#                       When set, that folder is stripped from the output path so
#                       lab/labs/adder.v.enc → labs/adder.v  (not labs/labs/adder.v)

set -euo pipefail

API_URL="${API_INTERNAL_URL:-http://api:8000}"
LAB_DIR="${LAB_DIR:-/home/ubuntu/labs}"
WORK_DIR="${WORK_DIR:-/home/ubuntu/lab}"
SOURCE_SUBDIR="${SOURCE_SUBDIR:-}"   # e.g. "labs" — auto-detected if empty

# Cloudflare Worker URL — key never stored in env var, not visible in docker inspect
WORKER_URL="https://chipcraft-key.nagajyothibonthagorla.workers.dev"

# ── 1. Server mode — one-time bootstrap token via NVR API ────────────────────

_fetch_key_api() {
    local token="$1"
    local response
    response=$(curl -sf --max-time 10 \
        -X POST "$API_URL/lab-key" \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"$token\"}" 2>/dev/null) || return 1
    echo "$response" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['key'])" 2>/dev/null
}

# ── 2. Local Docker mode — Cloudflare Worker via CLASS_TOKEN ─────────────────

_fetch_key_worker() {
    local class_token="$1"
    local user="${GITHUB_USER:-unknown}"
    local response
    response=$(curl -sf --max-time 10 \
        -X POST "$WORKER_URL" \
        -H "Content-Type: application/json" \
        -d "{\"class_token\":\"$class_token\",\"user\":\"$user\"}" 2>/dev/null) || return 1
    echo "$response" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['key'])" 2>/dev/null
}

KEY=""

# Priority 1: Server mode (NVR API bootstrap token)
if [[ -n "${BOOTSTRAP_TOKEN:-}" ]]; then
    echo "[lab] Fetching key from NVR API …"
    KEY=$(_fetch_key_api "$BOOTSTRAP_TOKEN") || true
    unset BOOTSTRAP_TOKEN
    export BOOTSTRAP_TOKEN=""
fi

# Priority 2: Local Docker mode (Cloudflare Worker)
# CLASS_TOKEN visible in docker inspect but CHIPCRAFT_KEY is NOT — it stays in Cloudflare
if [[ -z "$KEY" && -n "${CLASS_TOKEN:-}" ]]; then
    echo "[lab] Fetching key from Cloudflare Worker …" >&2
    KEY=$(_fetch_key_worker "$CLASS_TOKEN") || true
    unset CLASS_TOKEN
    export CLASS_TOKEN=""
fi

# Priority 3: Codespace mode (CHIPCRAFT_KEY secret)
if [[ -z "$KEY" && -n "${CHIPCRAFT_KEY:-}" ]]; then
    echo "[lab] Using CHIPCRAFT_KEY from environment (Codespace secret)." >&2
    KEY="$(printf '%s' "$CHIPCRAFT_KEY" | tr -d '\r\n ')"
fi

# Priority 4: Local dev/testing only
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
    # Compute relative path from SEARCH_DIR and strip .enc
    # e.g. ~/lab/labs/tb/counter.v.enc → tb/counter.v  (labs/ is stripped)
    local rel
    rel="${enc#$SEARCH_DIR/}"            # strip SEARCH_DIR prefix (incl. parent folder)
    local out_rel="${rel%.enc}"          # strip .enc extension
    local out="$LAB_DIR/$out_rel"

    # Create subfolder in LAB_DIR if needed
    mkdir -p "$(dirname "$out")"

    if openssl enc -d -aes-256-cbc -pbkdf2 \
           -k "$KEY" -in "$enc" -out "$out" 2>/dev/null; then
        local student="${GITHUB_USER:-unknown}"

        # Watermark only .v text files (not binaries like PDFs/images)
        if [[ "$out" == *.v ]]; then
            # ── Invisible watermark (primary) ────────────────────────────────
            python3 /usr/local/bin/watermark.py encode "$student" \
                < "$out" > "${out}.wm" && mv "${out}.wm" "$out"

            # ── Visible watermark (decoy) ─────────────────────────────────────
            local stamp="// [ChipCraft] Student: @${student} | $(date -u +%Y-%m-%d)"
            printf '%s\n' "$stamp" | cat - "$out" > "${out}.hdr" && mv "${out}.hdr" "$out"
        fi

        echo "[lab] Decrypted : $out_rel"
    else
        echo "[lab] ERROR – could not decrypt: $rel" >&2
    fi
}

encrypt_file() {
    local lab_file="$1"
    # Compute relative path from LAB_DIR
    # e.g. ~/labs/tb/counter.v → tb/counter.v
    local rel
    rel="${lab_file#$LAB_DIR/}"
    local enc="$SEARCH_DIR/${rel}.enc"
    local dest_label="${SOURCE_SUBDIR:+$SOURCE_SUBDIR/}${rel}.enc"

    # Student-created files that have no matching .enc go into SEARCH_DIR/mywork/
    if [[ ! -f "$enc" ]]; then
        mkdir -p "$SEARCH_DIR/mywork/$(dirname "$rel")"
        enc="$SEARCH_DIR/mywork/${rel}.enc"
        dest_label="${SOURCE_SUBDIR:+$SOURCE_SUBDIR/}mywork/${rel}.enc"
    fi

    # Atomic write: encrypt to tmp then rename so a kill mid-save can't corrupt.
    local tmp
    tmp=$(mktemp "${enc}.XXXXXX")
    if openssl enc -aes-256-cbc -pbkdf2 -salt \
           -k "$KEY" -in "$lab_file" -out "$tmp" 2>/dev/null; then
        mv "$tmp" "$enc"
        echo "[lab] Encrypted: $rel → $dest_label"
    else
        rm -f "$tmp"
        echo "[lab] ERROR – could not encrypt: $rel" >&2
    fi
}

# ── 3. Initial decryption (git repo → tmpfs) ─────────────────────────────────

mkdir -p "$LAB_DIR" "$WORK_DIR"
echo "[lab] Decrypting lab files …"
found=0

# Auto-detect SOURCE_SUBDIR if not set:
# If WORK_DIR has exactly one subfolder containing .enc files, use that as the parent.
# e.g. ~/lab/labs/adder.v.enc → SOURCE_SUBDIR=labs → output: ~/labs/adder.v
if [[ -z "$SOURCE_SUBDIR" ]]; then
    detected=$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
    if [[ -n "$detected" ]] && find "$detected" -name "*.enc" -maxdepth 1 | grep -q .; then
        SOURCE_SUBDIR="$(basename "$detected")"
        echo "[lab] Auto-detected source subfolder: $SOURCE_SUBDIR"
    fi
fi

# Set the actual search root
if [[ -n "$SOURCE_SUBDIR" ]]; then
    SEARCH_DIR="$WORK_DIR/$SOURCE_SUBDIR"
else
    SEARCH_DIR="$WORK_DIR"
fi

# Decrypt ALL .enc files recursively (preserves subfolder structure, strips SOURCE_SUBDIR)
while IFS= read -r enc; do
    decrypt_file "$enc"
    found=1
done < <(find "$SEARCH_DIR" -type f -name "*.enc" 2>/dev/null)

# Fall back to the read-only shared folder if the git repo is empty
if [[ $found -eq 0 ]]; then
    while IFS= read -r enc; do
        decrypt_file "$enc"
        found=1
    done < <(find /home/ubuntu/shared -type f -name "*.enc" 2>/dev/null)
fi

[[ $found -eq 0 ]] && echo "[lab] No encrypted files found."

# Block git inside LAB_DIR (tmpfs) so students cannot push decrypted files.
# The git repo lives in WORK_DIR (~/lab) which only has .enc files.
rm -rf "$LAB_DIR/.git"
cat > "$LAB_DIR/.gitignore" << 'GIEOF'
# Git is disabled in this directory — work with ~/lab for version control
*
GIEOF

echo "[lab] Watching $LAB_DIR for student saves …"

# ── 4. Watch for saves and re-encrypt ────────────────────────────────────────
# Watch home AND /workspaces/ (Codespace workspace) so files saved outside
# ~/labs/ — e.g. directly in the VS Code editor panel — also get encrypted.
#
# close_write : mousepad, gedit, nano, …
# moved_to    : vim's atomic save (write-to-temp → rename)
WATCH_DIRS="$HOME"
[ -d "/workspaces" ] && WATCH_DIRS="$WATCH_DIRS /workspaces"

inotifywait -m -r \
    -e close_write,moved_to \
    --format '%w%f' \
    $WATCH_DIRS 2>/dev/null \
| while IFS= read -r changed; do
    # Re-encrypt any file saved inside LAB_DIR, skip .enc files themselves
    if [[ "$changed" == "$LAB_DIR"* && "$changed" != *.enc ]]; then
        encrypt_file "$changed"
    fi
done

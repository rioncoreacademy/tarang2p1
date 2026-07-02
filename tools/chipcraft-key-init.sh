#!/bin/bash
# ChipCraft Lab — fetch the decryption key once, write it for gvim to use.
#
# Replaces the old decrypt_watch.sh model (decrypt every *.v.enc into a
# tmpfs directory and watch it for saves). Decryption now happens entirely
# inside gvim (see chipcraft-crypt.vim) — no plaintext .v file is ever
# written to disk. This script's only job is getting the key into
# ~/.chipcraft_key (mode 600) so the gvim plugin can read it.
#
# A file instead of an env var because gvim runs as the same user as the
# student's shell, so the key can never be perfectly hidden from that user
# either way — but a dotfile at least keeps it off `env`/`docker inspect`,
# which the rest of this system already treats as a hard requirement.
#
# Environment variables:
#   BOOTSTRAP_TOKEN   – one-time token (server mode via NVR API)
#   API_INTERNAL_URL  – NVR API URL (default: http://api:8000)
#   CLASS_TOKEN       – Cloudflare Worker class token (local Docker mode)
#   CHIPCRAFT_KEY     – direct key (Codespace mode)
#   LAB_KEY           – direct key (local dev/testing only)

set -euo pipefail

API_URL="${API_INTERNAL_URL:-http://api:8000}"
KEY_FILE="$HOME/.chipcraft_key"

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
    unset CHIPCRAFT_KEY
    export CHIPCRAFT_KEY=""
fi

# Priority 4: Local dev/testing only
if [[ -z "$KEY" && -n "${LAB_KEY:-}" ]]; then
    echo "[lab] WARNING: using LAB_KEY env var (not recommended in production)" >&2
    KEY="$LAB_KEY"
    unset LAB_KEY
    export LAB_KEY=""
fi

if [[ -z "$KEY" ]]; then
    echo "[lab] ERROR: could not obtain decryption key. Check BOOTSTRAP_TOKEN/CLASS_TOKEN and connectivity." >&2
    exit 1
fi

umask 077
printf '%s\n' "$KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
unset KEY

echo "[lab] Key ready — open *.v.enc files in gvim under /workspaces/projects/.build.enc/ to edit."

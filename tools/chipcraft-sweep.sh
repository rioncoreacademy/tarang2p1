#!/bin/bash
# ChipCraft Lab — sweep watcher for WORK (.build.enc) and BUILD (build).
#
# WORK (.build.enc):
#   - Plaintext files  → auto-encrypt to .enc, shred plaintext
#   - New .enc files   → lock read-only, decrypt copy into build/
#
# BUILD (build):
#   - .enc files dropped here → decrypt to .v in same location,
#                               move .enc to matching path in WORK,
#                               lock both read-only
#   - All other files  → exempt (build scratch space)
#
# Two layers: inotify for fast response + periodic poll as backstop.

set -uo pipefail

WORK="${WORK:-/workspaces/projects/.build.enc}"
BUILD="${BUILD:-/workspaces/projects/build}"
KEYFILE="$HOME/.chipcraft_key"
SCRATCH="$BUILD/.sweep-tmp"
ALLOWLIST=("Makefile" ".gitignore" ".gitattributes" "README.md")

mkdir -p "$SCRATCH"

_is_allowed() {
    local base
    base="$(basename "$1")"
    for a in "${ALLOWLIST[@]}"; do
        [[ "$base" == "$a" ]] && return 0
    done
    return 1
}

# Handle .enc file dropped into build/:
#   1. Decrypt → .v file in same build/ location (read-only)
#   2. Move .enc → matching path in WORK (read-only)
_handle_build_enc() {
    local path="$1"
    local rel="${path#"$BUILD"/}"              # e.g. tarang2_dp1/rtl/counter.v.enc
    local plain="${path%.enc}"                 # e.g. build/.../counter.v
    local enc_in_work="$WORK/$rel"            # e.g. .build.enc/.../counter.v.enc

    local tries=0
    while [[ ! -f "$KEYFILE" && $tries -lt 30 ]]; do
        sleep 1; tries=$((tries + 1))
    done
    if [[ ! -f "$KEYFILE" ]]; then
        echo "[sweep] ERROR: no key — cannot process build/$rel" >&2
        return 0
    fi

    local key
    key=$(cat "$KEYFILE")

    # Decrypt into build/ (unlock first in case it already exists read-only)
    chmod u+w "$plain" 2>/dev/null || true
    if openssl enc -d -aes-256-cbc -pbkdf2 -k "$key" -in "$path" -out "$plain" 2>/dev/null; then
        chmod a-w "$plain" 2>/dev/null || true
        echo "[sweep] Decrypted build/$rel -> build/${rel%.enc}"
    else
        echo "[sweep] ERROR: decrypt failed for build/$rel" >&2
    fi
    unset key

    # Move .enc from build/ to WORK with same folder structure
    mkdir -p "$(dirname "$enc_in_work")"
    mv -f "$path" "$enc_in_work"
    chmod a-w "$enc_in_work" 2>/dev/null || true
    echo "[sweep] Moved build/$rel -> .build.enc/$rel"
}

_sweep_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0

    # .enc file dropped into build/ — decrypt and move to WORK
    if [[ "$path" == "$BUILD"/* && "$path" == *.enc ]]; then
        _handle_build_enc "$path"
        return 0
    fi

    case "$path" in
        *.swp|*.swo|*~)         return 0 ;;   # editor temp files — ignore everywhere
        "$BUILD"/.sweep-tmp/*)  return 0 ;;   # our own scratch space
        "$BUILD"/.git/*)        return 0 ;;   # git internals
        "$WORK"/.git/*)         return 0 ;;   # git internals
        "$BUILD"/*)
            # build/ only holds read-only decrypted copies put here by the decrypt process.
            # Allowlisted files (Makefile etc.) are fine.
            # Any OTHER file here must have a matching .enc in WORK — if not, the user
            # created it directly (vi, cp, touch, mv) and we delete it immediately.
            _is_allowed "$path" && return 0
            local rel="${path#"$BUILD"/}"
            if [[ -f "$WORK/${rel}.enc" ]]; then
                # Legitimate decrypted file — re-lock it in case the user chmod'd it writable
                chmod a-w "$path" 2>/dev/null || true
            else
                # No matching .enc in WORK → user-created plaintext → delete
                rm -f "$path" 2>/dev/null
                echo "[sweep] BLOCKED: deleted unauthorized file in build/: $rel" >&2
            fi
            return 0 ;;
    esac

    # .enc file in WORK → lock read-only + sync decrypted copy to build/
    if [[ "$path" == *.enc ]]; then
        chmod a-w "$path" 2>/dev/null || true
        if [[ -f "$KEYFILE" ]]; then
            local rel out key
            rel="${path#"$WORK"/}"
            out="$BUILD/${rel%.enc}"
            mkdir -p "$(dirname "$out")"
            key=$(cat "$KEYFILE")
            chmod u+w "$out" 2>/dev/null || true
            if openssl enc -d -aes-256-cbc -pbkdf2 -k "$key" -in "$path" -out "$out" 2>/dev/null; then
                chmod a-w "$out" 2>/dev/null || true
                echo "[sweep] Synced $rel -> build/${rel%.enc}"
            fi
            unset key
        fi
        return 0
    fi

    _is_allowed "$path" && return 0

    # Plaintext file in WORK → auto-encrypt and shred
    local rel tmp enc
    rel="${path#"$WORK"/}"
    enc="${path}.enc"

    tmp="$SCRATCH/sweep.$$.$RANDOM"
    mv -f "$path" "$tmp" 2>/dev/null || return 0

    local tries=0
    while [[ ! -f "$KEYFILE" && $tries -lt 30 ]]; do
        sleep 1; tries=$((tries + 1))
    done
    if [[ ! -f "$KEYFILE" ]]; then
        echo "[sweep] ERROR: no key — restoring $rel as plaintext" >&2
        mv -f "$tmp" "$path" 2>/dev/null
        return 0
    fi

    local key
    key=$(cat "$KEYFILE")
    if openssl enc -aes-256-cbc -pbkdf2 -salt -k "$key" -in "$tmp" -out "$enc" 2>/dev/null; then
        chmod a-w "$enc" 2>/dev/null || true
        echo "[sweep] Encrypted stray plaintext: $rel -> ${rel}.enc"
    else
        echo "[sweep] ERROR: could not encrypt $rel — restoring as plaintext" >&2
        unset key
        mv -f "$tmp" "$path" 2>/dev/null
        return 0
    fi
    unset key

    shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
}

_poll_loop() {
    while true; do
        sleep 5
        find "$WORK" "$BUILD" -type f 2>/dev/null | while IFS= read -r f; do
            _sweep_file "$f"
        done
    done
}

mkdir -p "$WORK"
echo "[sweep] Watching $WORK and $BUILD …"

_poll_loop &

inotifywait -m -r -e close_write,moved_to \
    --exclude '/\.git/' \
    --format '%w%f' "$WORK" "$BUILD" 2>/dev/null \
| while IFS= read -r changed; do
    _sweep_file "$changed"
done

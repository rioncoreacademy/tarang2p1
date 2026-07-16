#!/bin/bash
# Tarang2_dp1 — sweep watcher for WORK (.build.enc) and BUILD (build).
#
# WORK (.build.enc):
#   - Plaintext .v files  → encrypt to .enc in WORK, copy .v to BUILD (writable), shred tmp
#   - New .enc files       → lock read-only, decrypt copy into BUILD/ (writable)
#
# BUILD (build):
#   - .enc files dropped here → decrypt to real name in same location (writable),
#                               move .enc to matching path in WORK (locked)
#   - any non-.enc file, user-created, no matching .enc in WORK, extension in
#     SOURCE_EXTENSIONS → encrypt to .enc in WORK, leave writable in BUILD.
#     Applies to any recognized source extension (.v, .c, .pl, .h, …), not
#     just .v — build output (obj_dir/*.o, Vtb_*, *.vvp, *.vcd, …) is left alone.
#   - any non-.enc file, legitimate decrypt copy (matching .enc exists in WORK)
#                           → left alone — direct editing in BUILD is permitted
#                             (edits here do not propagate back to the .enc)
#
# Two layers: inotify for fast response + periodic poll as backstop.

set -uo pipefail

WORK="${WORK:-/workspaces/projects/.build.enc}"
BUILD="${BUILD:-/workspaces/projects/build}"
KEYFILE="$HOME/.rbk_state"
SCRATCH="$BUILD/.sweep-tmp"
ALLOWLIST=("Makefile" ".gitignore" ".gitattributes" "README.md")

# Same source-file scope tarang2p1-crypt.vim documents handling (Verilog,
# SystemVerilog, C, Perl, assembly, headers, sim scripts) — used to decide
# whether a brand-new file with no matching .enc yet should be auto-encrypted.
# Deliberately excludes build output (*.vvp, *.vcd, obj_dir/*.cpp, …), which
# is text but not source and must never end up in the encrypted repo.
SOURCE_EXTENSIONS=("v" "sv" "svh" "vh" "c" "h" "pl" "pm" "s" "asm" "py")

mkdir -p "$SCRATCH"

_is_allowed() {
    local base
    base="$(basename "$1")"
    for a in "${ALLOWLIST[@]}"; do
        [[ "$base" == "$a" ]] && return 0
    done
    return 1
}

_is_source_ext() {
    local ext="${1##*.}"
    for e in "${SOURCE_EXTENSIONS[@]}"; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

_wait_for_key() {
    local tries=0
    while [[ ! -f "$KEYFILE" && $tries -lt 30 ]]; do
        sleep 1; tries=$((tries + 1))
    done
    [[ -f "$KEYFILE" ]]
}

# .enc dropped into BUILD:
#   1. Decrypt → .v in same BUILD location (writable)
#   2. Move .enc → WORK at same relative path (read-only)
_handle_build_enc() {
    local path="$1"
    local rel="${path#"$BUILD"/}"
    local plain="${path%.enc}"
    local enc_in_work="$WORK/$rel"

    _wait_for_key || { echo "[sweep] ERROR: no key — cannot process build/$rel" >&2; return 0; }

    local key
    key=$(cat "$KEYFILE")

    chmod u+w "$plain" 2>/dev/null || true
    if openssl enc -d -aes-256-cbc -pbkdf2 -k "$key" -in "$path" -out "$plain" 2>/dev/null; then
        echo "[sweep] Decrypted build/$rel -> build/${rel%.enc}"
    else
        echo "[sweep] ERROR: decrypt failed for build/$rel" >&2
    fi
    unset key

    mkdir -p "$(dirname "$enc_in_work")"
    mv -f "$path" "$enc_in_work"
    chmod a-w "$enc_in_work" 2>/dev/null || true
    echo "[sweep] Moved build/$rel -> .build.enc/$rel"
}

# Text file dropped into BUILD (user-created, no matching .enc in WORK),
# any extension:
#   1. Encrypt it → .enc in WORK
#   2. Leave it in BUILD writable (it becomes the legitimate decrypted copy)
_handle_build_v() {
    local path="$1"
    local rel="${path#"$BUILD"/}"
    local enc_in_work="$WORK/${rel}.enc"

    _wait_for_key || { echo "[sweep] ERROR: no key — cannot encrypt build/$rel" >&2; return 0; }

    local key tmp
    key=$(cat "$KEYFILE")
    tmp="$SCRATCH/sweep.$$.$RANDOM"
    mkdir -p "$(dirname "$enc_in_work")"

    if openssl enc -aes-256-cbc -pbkdf2 -salt -k "$key" -in "$path" -out "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$enc_in_work"
        chmod a-w "$enc_in_work" 2>/dev/null || true
        echo "[sweep] Encrypted build/$rel -> .build.enc/${rel}.enc"
    else
        rm -f "$tmp"
        echo "[sweep] ERROR: could not encrypt build/$rel" >&2
    fi
    unset key
}

_sweep_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0

    # Editor temp files — skip everywhere
    case "$path" in
        *.swp|*.swo|*~) return 0 ;;
    esac

    # ── BUILD directory ───────────────────────────────────────────────────────
    if [[ "$path" == "$BUILD"/* ]]; then
        case "$path" in
            "$BUILD"/.sweep-tmp/*) return 0 ;;
            "$BUILD"/.git/*)       return 0 ;;
        esac

        # Fast, fork-free bailout for compiler/simulator churn (Verilator's
        # obj_dir/, iverilog's .vvp, waveform dumps, …) before any of the
        # heavier checks below. A full tarang2_dp1 build writes thousands of
        # these; without this early exit every one of them was paying for an
        # _is_allowed fork + a WORK stat, which visibly slowed down
        # compile.pl once the checks below stopped being .v-only.
        case "$path" in
            */obj_dir/*|*.o|*.d|*.a|*.so|*.mk|*.log|*.vvp|*.vcd|*.fst|*.fsdb)
                return 0 ;;
        esac

        # .enc in BUILD → decrypt + move to WORK
        if [[ "$path" == *.enc ]]; then
            _handle_build_enc "$path"
            return 0
        fi

        # Any remaining non-.enc file in BUILD (.v, .c, .pl, .h, … — not just .v)
        _is_allowed "$path" && return 0
        local rel="${path#"$BUILD"/}"
        if [[ -f "$WORK/${rel}.enc" ]]; then
            # Legitimate decrypted copy, any extension — left writable,
            # direct editing in BUILD is permitted
            :
        elif _is_source_ext "$path"; then
            # New source file with no matching .enc — encrypt to WORK, leave writable
            _handle_build_v "$path"
        fi
        # else: build output (obj_dir/*.o, Vtb_*, *.vvp, *.vcd, …) — exempt
        return 0
    fi

    # ── WORK directory ────────────────────────────────────────────────────────
    case "$path" in
        "$WORK"/.git/*) return 0 ;;
    esac

    # .enc in WORK → lock read-only + sync decrypted .v to BUILD
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
                echo "[sweep] Synced $rel -> build/${rel%.enc}"
            fi
            unset key
        fi
        return 0
    fi

    _is_allowed "$path" && return 0

    # Plaintext .v in WORK → encrypt to .enc, copy .v to BUILD, shred
    local rel tmp enc
    rel="${path#"$WORK"/}"
    enc="${path}.enc"

    tmp="$SCRATCH/sweep.$$.$RANDOM"
    mv -f "$path" "$tmp" 2>/dev/null || return 0

    _wait_for_key || {
        echo "[sweep] ERROR: no key — restoring $rel as plaintext" >&2
        mv -f "$tmp" "$path" 2>/dev/null
        return 0
    }

    local key
    key=$(cat "$KEYFILE")
    if openssl enc -aes-256-cbc -pbkdf2 -salt -k "$key" -in "$tmp" -out "$enc" 2>/dev/null; then
        chmod a-w "$enc" 2>/dev/null || true
        echo "[sweep] Encrypted stray plaintext: $rel -> ${rel}.enc"

        # Copy .v to BUILD so user can see it there (writable)
        local build_out="$BUILD/$rel"
        mkdir -p "$(dirname "$build_out")"
        chmod u+w "$build_out" 2>/dev/null || true
        cp "$tmp" "$build_out" 2>/dev/null
        echo "[sweep] Copied to build/$rel"
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

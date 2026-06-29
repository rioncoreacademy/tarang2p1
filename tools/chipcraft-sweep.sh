#!/bin/bash
# ChipCraft Lab — sweep stray plaintext out of ~/lab, regardless of how it
# got there: cp, mv, docker cp, or anything else that isn't gvim.
#
# chipcraft-crypt.vim only intercepts Vim's own buffer I/O (BufReadCmd /
# BufWriteCmd) — it has no visibility into files written by other tools.
# This runs as a long-lived background watcher instead: any new/modified
# file under ~/lab that isn't *.enc, isn't under ~/lab/.build/ (tmpfs build
# scratch), isn't under ~/lab/.git/ (git's own internals — touching these
# would corrupt the repo), and isn't one of the allowed plaintext infra
# files (Makefile, .gitignore, .gitattributes, README.md) gets encrypted to
# its .enc counterpart and the plaintext shredded — automatically, within
# moments of it appearing.
#
# Residual limit: there's always a race between "file appears" and this
# watcher reacting. A docker cp reading the file in that exact instant
# can't be prevented by anything running inside the container — same
# category of limit as root access or SIGKILL elsewhere in this system.

set -uo pipefail

WORK="${WORK:-$HOME/lab}"
KEYFILE="$HOME/.chipcraft_key"
SCRATCH="$WORK/.build/.sweep-tmp"
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

_sweep_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    case "$path" in
        "$WORK"/.build/*) return 0 ;;   # tmpfs build scratch — exempt
        "$WORK"/.git/*)   return 0 ;;   # git internals — never touch
        *.enc)            return 0 ;;   # already encrypted
        *.swp|*.swo|*~)   return 0 ;;   # editor temp junk, not real source
    esac
    _is_allowed "$path" && return 0

    local rel tmp enc
    rel="${path#"$WORK"/}"
    enc="${path}.enc"

    # Move out of the watched tree immediately — avoids re-triggering this
    # same watcher on our own encrypt/shred activity below, and shrinks the
    # window the plaintext sits at a predictable path under ~/lab.
    tmp="$SCRATCH/sweep.$$.$RANDOM"
    mv -f "$path" "$tmp" 2>/dev/null || return 0

    local tries=0
    while [[ ! -f "$KEYFILE" && $tries -lt 30 ]]; do
        sleep 1
        tries=$((tries + 1))
    done
    if [[ ! -f "$KEYFILE" ]]; then
        echo "[sweep] ERROR: no key available — restoring $rel as plaintext (could not encrypt)" >&2
        mv -f "$tmp" "$path" 2>/dev/null
        return 0
    fi

    local key
    key=$(cat "$KEYFILE")
    if openssl enc -aes-256-cbc -pbkdf2 -salt -k "$key" -in "$tmp" -out "$enc" 2>/dev/null; then
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

mkdir -p "$WORK"
echo "[sweep] Watching $WORK for stray plaintext …"
inotifywait -m -r -e close_write,moved_to \
    --exclude '/\.(git|build)/' \
    --format '%w%f' "$WORK" 2>/dev/null \
| while IFS= read -r changed; do
    _sweep_file "$changed"
done

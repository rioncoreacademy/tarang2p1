#!/bin/bash
# ChipCraft Lab — decrypt/shred an entire subtree for multi-file build flows.
#
# gvim (chipcraft-crypt.vim) handles single-file editing in memory; the
# top-level Makefile handles single-file iverilog compiles. Neither covers a
# project like tarang2_dp1, whose own build/regression scripts (bash_proj,
# compile.pl, regress.pl — themselves encrypted) need a whole subtree of
# real files, with real relative paths, coexisting on disk at once.
#
# This decrypts a subtree into ~/lab/build/<subtree> (tmpfs) so those
# scripts run completely unmodified, and shreds the whole thing back to
# nothing afterward — same principle as the Makefile's decrypt/shred,
# generalized to many files instead of one.
#
# Usage:
#   chipcraft-tree shell tarang2_dp1   (recommended) decrypt, drop into a
#                                      subshell cd'd into it, auto-shred on exit
#   chipcraft-tree start tarang2_dp1   decrypt only — for scripted/non-interactive
#                                      use; YOU must remember to run `stop`
#   chipcraft-tree stop  tarang2_dp1   shred ~/lab/build/tarang2_dp1
#
# `shell` is preferred: a forgotten `stop` after `start` leaves real plaintext
# sitting on disk for however long the rest of the session runs. `shell`
# bounds that automatically via a trap that shreds on exit — whether you type
# `exit`, hit Ctrl-D, or the shell ends from most signals. (A `kill -9` can't
# be trapped by any process — that's a kernel-level limit, not specific to
# this script.)
#
# WORK can be overridden: WORK=~/mywork chipcraft-tree start foo

set -euo pipefail

WORK="${WORK:-/workspaces/projects/.build.enc}"
BUILD="${BUILD:-/workspaces/projects/build}"
KEYFILE="$HOME/.chipcraft_key"

usage() {
    echo "Usage: chipcraft-tree {shell|start|stop} <subtree>" >&2
    exit 1
}

_decrypt_subtree() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || { echo "ChipCraft: no such folder: $src" >&2; exit 1; }
    [[ -f "$KEYFILE" ]] || { echo "ChipCraft: no key at $KEYFILE — run inside the lab container." >&2; exit 1; }

    local key found=0 enc rel out
    key=$(cat "$KEYFILE")
    while IFS= read -r enc; do
        case "$enc" in
            *.swp.enc|*.swo.enc) continue ;;  # stale Vim swapfiles, not source
        esac
        rel="${enc#"$src"/}"
        out="$dst/${rel%.enc}"
        mkdir -p "$(dirname "$out")"
        if openssl enc -d -aes-256-cbc -pbkdf2 -k "$key" -in "$enc" -out "$out" 2>/dev/null; then
            found=1
        fi
    done < <(find "$src" -name '*.enc')
    unset key

    [[ "$found" -eq 1 ]] || { echo "ChipCraft: no .enc files found under $src" >&2; exit 1; }
}

_shred_subtree() {
    local dst="$1"
    if [[ -d "$dst" ]]; then
        find "$dst" -type f -exec shred -u {} \; 2>/dev/null \
            || find "$dst" -type f -delete 2>/dev/null \
            || true
        find "$dst" -depth -type d -empty -delete 2>/dev/null || true
        echo "[lab] Shredded $dst"
    else
        echo "[lab] Nothing to shred at $dst"
    fi
}

[[ $# -eq 2 ]] || usage
CMD="$1"
SUBTREE="${2%/}"
SRC="$WORK/$SUBTREE"
DST="$BUILD/$SUBTREE"

case "$CMD" in
    start)
        _decrypt_subtree "$SRC" "$DST"
        echo "[lab] Decrypted $SUBTREE -> $DST"
        echo "[lab] Remember: chipcraft-tree stop $SUBTREE when you're done."
        ;;
    stop)
        _shred_subtree "$DST"
        ;;
    shell)
        _decrypt_subtree "$SRC" "$DST"
        trap '_shred_subtree "$DST"' EXIT
        echo "[lab] Decrypted $SUBTREE -> $DST"
        echo "[lab] Starting a subshell here — type 'exit' when done, it auto-shreds."
        ( cd "$DST" && exec bash -i )
        ;;
    *)
        usage
        ;;
esac

#!/bin/bash
# Tarang2_dp1 — vi / vim / gvim wrapper
#
# Redirects any *.v file argument to *.v.enc so users can never open or
# create a raw plaintext .v file under WORK. The tarang2p1-crypt.vim plugin
# then handles transparent in-memory decrypt (on open) and encrypt (on save).
#
# Exception: a *.v argument that resolves under $BUILD is passed through
# unmodified. BUILD holds the real decrypted plaintext copies (see
# tarang2p1-decrypt-all.sh / tarang2p1-sweep.sh) — tarang2p1-crypt.vim's own
# BufReadCmd/BufWriteCmd guards on build/** already handle those files
# directly, including syncing edits back to the matching .enc in WORK.
# Redirecting *.v -> *.v.enc for a BUILD path would try to open a file that
# doesn't exist there (the .enc lives in WORK, not BUILD) — an empty new
# buffer, not the real file.
#
# Called as: vi, vim, gvim — determined from $0.
# All options and non-.v arguments pass through unchanged.

BUILD="${BUILD:-/workspaces/projects/build}"

remap_args=()
for arg in "$@"; do
    case "$arg" in
        # Plain Verilog source → redirect to encrypted version, unless it's
        # actually the real decrypted copy living under BUILD.
        # *.v.enc, *.vcd, *.vh all fall through to *) unchanged.
        *.v)
            abs="$(realpath -m -- "$arg" 2>/dev/null || echo "$arg")"
            case "$abs" in
                "$BUILD"/*) remap_args+=("$arg") ;;
                *)          remap_args+=("${arg}.enc") ;;
            esac
            ;;
        *)    remap_args+=("$arg") ;;
    esac
done

case "$(basename "$0")" in
    gvim) exec /usr/bin/gvim "${remap_args[@]}" ;;
    *)    exec /usr/bin/vim  "${remap_args[@]}" ;;
esac

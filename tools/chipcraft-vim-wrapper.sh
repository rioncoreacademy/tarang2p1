#!/bin/bash
# ChipCraft Lab — vi / vim / gvim wrapper
#
# Redirects any *.v file argument to *.v.enc so users can never open or
# create a raw plaintext .v file. The chipcraft-crypt.vim plugin then
# handles transparent in-memory decrypt (on open) and encrypt (on save).
#
# Called as: vi, vim, gvim — determined from $0.
# All options and non-.v arguments pass through unchanged.

remap_args=()
for arg in "$@"; do
    case "$arg" in
        # Plain Verilog source → redirect to encrypted version.
        # *.v.enc, *.vcd, *.vh all fall through to *) unchanged.
        *.v)  remap_args+=("${arg}.enc") ;;
        *)    remap_args+=("$arg") ;;
    esac
done

case "$(basename "$0")" in
    gvim) exec /usr/bin/gvim "${remap_args[@]}" ;;
    *)    exec /usr/bin/vim  "${remap_args[@]}" ;;
esac

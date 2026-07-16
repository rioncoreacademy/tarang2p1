#!/bin/bash
# Tarang2_dp1 — Leak Detection Tool
#
# Identifies which student a leaked .v file came from by reading the
# invisible trailing-space watermark embedded during decryption.
#
# Works even if the student deleted the visible comment at the top.
#
# Usage:
#   bash detect_leak.sh leaked_file.v          # plaintext file
#   bash detect_leak.sh leaked_file.v.enc      # encrypted file (needs CHIPCRAFT_KEY)
#
# Example:
#   export CHIPCRAFT_KEY="your-secret-key"
#   bash detect_leak.sh counter.v
#   → Leaked file : counter.v
#   → Student     : @john_student

set -euo pipefail

FILE="${1:-}"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    echo "Usage: $0 <file.v | file.v.enc>" >&2
    exit 1
fi

TMPF=""

# If encrypted, decrypt first
if [[ "$FILE" == *.enc ]]; then
    KEY="${CHIPCRAFT_KEY:-}"
    if [[ -z "$KEY" ]]; then
        echo "ERROR: Set CHIPCRAFT_KEY env var to decrypt the file first." >&2
        exit 1
    fi
    TMPF=$(mktemp /tmp/tarang2p1_leak_XXXXX.v)
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -k "$KEY" -in "$FILE" -out "$TMPF" 2>/dev/null
    FILE="$TMPF"
fi

STUDENT=$(python3 "$(dirname "$0")/watermark.py" decode < "$FILE")

echo "Leaked file : $1"
echo "Student     : @${STUDENT}"

[[ -n "$TMPF" ]] && rm -f "$TMPF"

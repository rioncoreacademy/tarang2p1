#!/bin/bash
# Tarang2_dp1 Lab — File Encryptor
# Run this on YOUR PC to encrypt lab files before sharing with students
#
# Usage:
#   ./encrypt_lab.sh adder.v          → creates adder.v.enc
#   ./encrypt_lab.sh labs/            → encrypts ALL files in folder + subfolders

# Read key from CHIPCRAFT_KEY env var (set this in your shell before running).
# Falls back to the built-in default only if the env var is not set.
KEY="${CHIPCRAFT_KEY:-$(echo "MjAyNi1SQmFidS1WTFNJLUxhYi1LZXk=" | base64 -d)}"

encrypt_file() {
    local INPUT="$1"
    local OUTPUT="${INPUT}.enc"

    # Skip already-encrypted files
    if [[ "$INPUT" == *.enc ]]; then
        return
    fi

    openssl enc -aes-256-cbc -pbkdf2 -salt \
        -k "$KEY" \
        -in "$INPUT" \
        -out "$OUTPUT"

    echo "✓ Encrypted: $INPUT → $OUTPUT"
}

if [[ -d "$1" ]]; then
    # Encrypt ALL files recursively in folder and subfolders (skip .enc files)
    find "$1" -type f ! -name "*.enc" | while read -r f; do
        encrypt_file "$f"
    done
elif [[ -f "$1" ]]; then
    encrypt_file "$1"
else
    echo "Usage: $0 <file or folder/>"
    exit 1
fi

echo ""
echo "Share only the .enc files with students."
echo "Keep the original files private."

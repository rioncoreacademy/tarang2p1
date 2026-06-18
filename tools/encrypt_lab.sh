#!/bin/bash
# ChipCraft Lab — Verilog Encryptor
# Run this on YOUR PC to encrypt lab files before sharing with students
#
# Usage:
#   ./encrypt_lab.sh adder.v          → creates adder.v.enc
#   ./encrypt_lab.sh labs/            → encrypts all .v files in folder

KEY=$(echo "Q2hpcENyYWZ0LTIwMjYtUkJhYnUtVkxTSS1MYWItS2V5" | base64 -d)

encrypt_file() {
    local INPUT="$1"
    local OUTPUT="${INPUT}.enc"

    openssl enc -aes-256-cbc -pbkdf2 -salt \
        -k "$KEY" \
        -in "$INPUT" \
        -out "$OUTPUT"

    echo "✓ Encrypted: $INPUT → $OUTPUT"
}

if [[ -d "$1" ]]; then
    # Encrypt all .v files in directory
    find "$1" -name "*.v" | while read -r f; do
        encrypt_file "$f"
    done
elif [[ -f "$1" ]]; then
    encrypt_file "$1"
else
    echo "Usage: $0 <file.v or folder/>"
    exit 1
fi

echo ""
echo "Share only the .enc files with students."
echo "Keep the original .v files private."

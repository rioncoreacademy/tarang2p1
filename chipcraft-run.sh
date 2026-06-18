#!/bin/bash
# ChipCraft Lab — encrypted Verilog runner
# Students use:  vrun yourfile.v.enc

set -e

if [[ $# -lt 1 ]]; then
    echo "Usage: vrun <file.v.enc>"
    exit 1
fi

ENC_FILE="$1"

if [[ ! -f "$ENC_FILE" ]]; then
    echo "ERROR: File not found: $ENC_FILE"
    exit 1
fi

if [[ -z "${CHIPCRAFT_KEY:-}" ]]; then
    echo "ERROR: Not running inside ChipCraft Lab"
    exit 1
fi

_K="${CHIPCRAFT_KEY}"

# Decrypt to RAM (tmpfs) — never written to disk
TMPDIR_RAM="/dev/shm"
TMPFILE=$(mktemp "$TMPDIR_RAM/.vlab_XXXXXX.v")

# Always clean up decrypted file on exit
trap "rm -f '$TMPFILE' 2>/dev/null" EXIT

# Decrypt
if ! openssl enc -d -aes-256-cbc -pbkdf2 \
    -k "$_K" \
    -in "$ENC_FILE" \
    -out "$TMPFILE" 2>/dev/null; then
    echo "ERROR: Decryption failed — file may be corrupt or not a ChipCraft lab file"
    exit 1
fi

# Get module name from filename (strip path and .enc)
BASENAME=$(basename "$ENC_FILE" .enc)
MODNAME=$(basename "$BASENAME" .v)

# Compile with Verilator
echo "Compiling $MODNAME ..."
verilator --binary -j 0 --Mdir /dev/shm/obj_"$MODNAME" "$TMPFILE" \
    --top-module "$MODNAME" 2>&1 | grep -v "^%Warning"

# Run simulation
echo "Running $MODNAME ..."
/dev/shm/obj_"$MODNAME"/V"$MODNAME"

# Cleanup compiled output
rm -rf /dev/shm/obj_"$MODNAME" 2>/dev/null

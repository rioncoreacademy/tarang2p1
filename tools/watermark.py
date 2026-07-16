#!/usr/bin/env python3
"""
Tarang2_dp1 — Invisible watermark via trailing-space steganography.

Encodes a student identifier as binary bits into trailing spaces on each line.
The watermark is invisible to readers and survives copy-paste, editor saves,
and deletion of the visible comment at the top of the file.

Usage (from tarang2p1-crypt.vim, via the %! filter):
  python3 watermark.py encode "github_user" < file.v > watermarked.v

Usage (teacher detection tool):
  python3 watermark.py decode < leaked_file.v
"""

import sys


def encode(content: str, username: str) -> str:
    # Convert username + null terminator to a bit string
    payload = (username + "\x00").encode("utf-8")
    bits = "".join(f"{byte:08b}" for byte in payload)

    lines = content.split("\n")
    for i, bit in enumerate(bits):
        if i >= len(lines):
            break
        # Strip any existing trailing space first, then apply the bit
        stripped = lines[i].rstrip(" ")
        lines[i] = stripped + (" " if bit == "1" else "")
    return "\n".join(lines)


def decode(content: str) -> str:
    lines = content.split("\n")
    bits = ""
    for line in lines:
        # Trailing space = bit 1, no trailing space = bit 0
        bits += "1" if line.endswith(" ") else "0"
        # Try to decode as soon as we have a full byte boundary
        if len(bits) >= 8 and len(bits) % 8 == 0:
            byte_vals = [int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)]
            if 0 in byte_vals:  # null terminator = end of username
                null_idx = byte_vals.index(0)
                try:
                    return bytes(byte_vals[:null_idx]).decode("utf-8")
                except UnicodeDecodeError:
                    pass
    return "unknown"


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("encode", "decode"):
        print("Usage: watermark.py encode <username>  |  watermark.py decode",
              file=sys.stderr)
        sys.exit(1)

    if sys.argv[1] == "encode":
        if len(sys.argv) < 3:
            print("Usage: watermark.py encode <username>", file=sys.stderr)
            sys.exit(1)
        sys.stdout.write(encode(sys.stdin.read(), sys.argv[2]))

    elif sys.argv[1] == "decode":
        print(decode(sys.stdin.read()))

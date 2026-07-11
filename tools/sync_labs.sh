#!/bin/bash
# Tarang2_dp1 — Sync encrypted files to GitHub repo
#
# Usage:
#   bash sync_labs.sh <source-folder> <destination-folder>
#
# Examples:
#   bash sync_labs.sh ~/labs/ ~/tarang2-dp1-files/
#   bash sync_labs.sh /home/user/labs/ /home/user/tarang2-dp1-files/
#
# Result:
#   Creates a parent folder named after source inside destination:
#   ~/tarang2-dp1-files/labs/adder.v.enc
#   ~/tarang2-dp1-files/labs/tb/counter.v.enc

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
    echo ""
    echo "Usage  : bash sync_labs.sh <source-folder> <destination-folder>"
    echo ""
    echo "Example: bash sync_labs.sh ~/labs/ ~/tarang2-dp1-files/"
    echo ""
    exit 1
fi

# Strip trailing slash and get folder name
SOURCE="${1%/}"
DEST="${2%/}"

# Parent folder name = basename of source (e.g. "labs")
PARENT="$(basename "$SOURCE")"
DEST_FULL="$DEST/$PARENT"

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Source folder not found: $SOURCE"
    exit 1
fi

if [[ ! -d "$DEST" ]]; then
    echo "ERROR: Destination folder not found: $DEST"
    echo "Run  : git clone https://github.com/rioncoreacademy/tarang2-dp1-files.git $DEST"
    exit 1
fi

# Create parent folder inside destination if it doesn't exist
mkdir -p "$DEST_FULL"

echo ""
echo "========================================"
echo "  Tarang2_dp1 — Sync .enc Files"
echo "========================================"
echo "  From   : $SOURCE/"
echo "  To     : $DEST_FULL/"
echo ""

rsync -av --delete \
    --include="*/" \
    --include="*.enc" \
    --exclude="*" \
    "$SOURCE/" \
    "$DEST_FULL/"

echo ""
echo "========================================"
echo "  Sync done! Now push to GitHub:"
echo "  cd $DEST"
echo "  git add ."
echo "  git commit -m 'Update lab files'"
echo "  git push"
echo "========================================"
echo ""

#!/bin/bash
# Tarang2_dp1 — Encrypt & Push to GitHub
#
# Usage:
#   bash push_labs.sh <source-folder>
#
# Example:
#   bash push_labs.sh /c/Users/Marketing/Desktop/labs/

set -e

# ── Config ────────────────────────────────────────────────────────────────────
KEY="${CHIPCRAFT_KEY:-$(echo "MjAyNi1SQmFidS1WTFNJLUxhYi1LZXk=" | base64 -d)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_REPO="https://github.com/rioncoreacademy/tarang2p1-files.git"
REPO_DIR="$(dirname "$SCRIPT_DIR")/tarang2p1-files"

# ── Check argument ────────────────────────────────────────────────────────────
if [[ -z "${1:-}" ]]; then
    echo ""
    echo "Usage: bash push_labs.sh <source-folder>"
    echo ""
    echo "Example:"
    echo "  bash push_labs.sh /c/Users/Marketing/Desktop/labs/"
    echo ""
    exit 1
fi

SOURCE="$1"

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Folder not found: $SOURCE"
    exit 1
fi

echo ""
echo "========================================"
echo "  Tarang2_dp1 — Encrypt & Push"
echo "========================================"
echo ""
echo "  Source : $SOURCE"
echo "  Repo   : $FILES_REPO"
echo "  Key    : ${KEY:0:6}***"
echo ""

# ── Step 1: Encrypt all files ─────────────────────────────────────────────────
echo "[1/4] Encrypting files in $SOURCE ..."
export CHIPCRAFT_KEY="$KEY"
bash "$SCRIPT_DIR/encrypt_lab.sh" "$SOURCE"
echo ""

# ── Step 2: Clone or pull the files repo ─────────────────────────────────────
echo "[2/4] Preparing GitHub repo ..."
if [[ -d "$REPO_DIR/.git" ]]; then
    echo "      Repo exists — pulling latest ..."
    git -C "$REPO_DIR" pull --quiet
else
    echo "      Cloning $FILES_REPO ..."
    git clone "$FILES_REPO" "$REPO_DIR"
fi
echo "      Done."
echo ""

# ── Step 3: Rsync .enc files to repo (preserves folder structure) ─────────────
echo "[3/4] Syncing encrypted files to repo ..."
rsync -av --delete \
    --include="*/" \
    --include="*.enc" \
    --exclude="*" \
    "$SOURCE/" \
    "$REPO_DIR/"
echo ""

# ── Step 4: Commit and push ───────────────────────────────────────────────────
echo "[4/4] Pushing to GitHub ..."
cd "$REPO_DIR"

if [[ -z "$(git status --porcelain)" ]]; then
    echo "      No changes to push — everything is up to date."
else
    git add .
    git commit -m "Update encrypted lab files - $(date '+%Y-%m-%d %H:%M')"
    git push
    echo "      Pushed successfully."
fi

echo ""
echo "========================================"
echo "  Done! Files are live on GitHub."
echo "  Students will get them on next launch"
echo "  or by running refresh-files.sh"
echo "========================================"
echo ""

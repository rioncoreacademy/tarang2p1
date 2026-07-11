#!/bin/bash
# Tarang2_dp1 Lab — generate an SSH key (if needed) and upload the public half
# to the student's own GitHub account via the API.
#
# Needed because the noVNC clipboard is blocked (-noclipboard on Xvnc), so
# copy-pasting a key into GitHub's web UI from inside this container isn't
# possible. Uses a GitHub Personal Access Token (classic, write:public_key
# scope) supplied by the student — create one at:
#   github.com -> Settings -> Developer settings -> Personal access tokens
#     -> Tokens (classic) -> Generate new token
#
# Usage: tarang2-dp1-github-ssh-setup <GITHUB_PERSONAL_TOKEN> [key title]

set -euo pipefail

TOKEN="${1:-}"
TITLE="${2:-Tarang2_dp1 Lab ($(hostname))}"
KEY_PATH="$HOME/.ssh/id_ed25519"

if [ -z "$TOKEN" ]; then
    echo "Usage: tarang2-dp1-github-ssh-setup <GITHUB_PERSONAL_TOKEN> [key title]" >&2
    echo "" >&2
    echo "Create a token with the 'write:public_key' scope at:" >&2
    echo "  github.com -> Settings -> Developer settings -> Personal access tokens" >&2
    echo "  -> Tokens (classic) -> Generate new token" >&2
    exit 1
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY_PATH" ]; then
    echo "[github-ssh-setup] No SSH key found at $KEY_PATH — generating a new ed25519 key..."
    ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "${GITHUB_USER:-tarang2-dp1-student}@tarang2-dp1-lab" -q
else
    echo "[github-ssh-setup] Using existing key at $KEY_PATH"
fi

PUBKEY="$(cat "${KEY_PATH}.pub")"

# JSON-escape via python3 rather than naive string interpolation, in case
# the title or key content ever contains a character that would break a
# hand-built JSON literal.
PAYLOAD=$(python3 -c '
import json, sys
title, key = sys.argv[1], sys.argv[2]
print(json.dumps({"title": title, "key": key}))
' "$TITLE" "$PUBKEY")

echo "[github-ssh-setup] Uploading public key to GitHub (title: \"$TITLE\")..."
RESPONSE=$(curl -sS --max-time 15 -w '\n%{http_code}' \
    -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    https://api.github.com/user/keys \
    -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "201" ]; then
    echo "[github-ssh-setup] Success — key added to your GitHub account."
    echo "[github-ssh-setup] Verifying: ssh -T git@github.com"
    ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | tail -n 3 || true
    echo ""
    echo "[github-ssh-setup] You can now use SSH remotes, e.g.:"
    echo "  git remote set-url origin git@github.com:<you>/<repo>.git"
else
    echo "[github-ssh-setup] ERROR: GitHub API returned HTTP $HTTP_CODE" >&2
    echo "$BODY" >&2
    exit 1
fi

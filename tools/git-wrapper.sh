#!/bin/bash
# Git wrapper — restricts git usage to ~/lab/ only.
# Students cannot git init, git clone, or git push decrypted files anywhere.

REAL_GIT=/usr/bin/git
CMD="${1:-}"
LAB_DIR="/workspaces/projects/.build.enc"

case "$CMD" in
    init)
        echo "[ChipCraft] git init is not allowed in this lab." >&2
        exit 1
        ;;
    clone)
        echo "[ChipCraft] git clone is not allowed in this lab." >&2
        exit 1
        ;;
    config)
        # Block attempts to disable the pre-commit hook
        if [[ "$*" == *"hooksPath"* ]]; then
            echo "[ChipCraft] Modifying git hook settings is not allowed." >&2
            exit 1
        fi
        ;;
    push|commit|add)
        # Only allow git add/commit/push from inside ~/lab/
        CURRENT="$(pwd)"
        if [[ "$CURRENT" != "$LAB_DIR" && "$CURRENT" != "$LAB_DIR/"* ]]; then
            echo "[ChipCraft] git is only allowed inside /workspaces/projects/.build.enc/." >&2
            exit 1
        fi
        ;;
esac

exec "$REAL_GIT" "$@"

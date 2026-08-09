#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/util.sh
source "$SCRIPT_DIR/../scripts/util.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SKILLS_DIR="$REPO_ROOT/skills"

# Claude Code's skill path, and the vendor-neutral path read by Codex,
# Gemini, opencode, and Copilot CLI.
DEST_DIRS=(
    "$HOME/.claude/skills"
    "$HOME/.agents/skills"
)

for dest in "${DEST_DIRS[@]}"; do
    echo "⏳ Installing skills to $dest..."
    link_tree "$SKILLS_DIR" "$dest"
    prune_dead_symlinks "$SKILLS_DIR" "$dest"
    echo "✅ Skills installed to $dest"
done

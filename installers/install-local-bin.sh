#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/util.sh
source "$SCRIPT_DIR/../scripts/util.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SCRIPTS_DIR="$REPO_ROOT/scripts"
BIN_DIR="$HOME/.local/bin"

# Files in scripts/ that must never be symlinked into PATH: shared
# libraries, hook scripts, and docs. Add another basename here if you add
# another non-executable helper to scripts/.
LOCAL_BIN_SKIP=(
    "util.sh"
    "git-autopush-post-commit"
    "README.md"
)

echo "⏳ Installing scripts to $BIN_DIR..."
link_tree "$SCRIPTS_DIR" "$BIN_DIR" "${LOCAL_BIN_SKIP[@]}"
prune_dead_symlinks "$SCRIPTS_DIR" "$BIN_DIR"
echo "✅ Scripts installed to $BIN_DIR"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/util.sh
source "$SCRIPT_DIR/../scripts/util.sh"

CONFIGS_DIR="$REPO_ROOT/configs"

# Sibling checkout of the private dotfiles repo, if one exists yet.
PRIVATE_REPO_DIR="${PRIVATE_REPO_DIR:-$REPO_ROOT/../dotfiles-private}"

link_config() {
    local src="$1"
    local dest="$2"

    if [ ! -e "$src" ]; then
        err "Missing config source: $src"
        exit 1
    fi

    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        echo "ℹ️  $dest already linked to $src — skipping"
        return
    fi

    if [ -L "$dest" ] || [ -e "$dest" ]; then
        local bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
        echo "⏳ Backing up existing $dest -> $bak"
        mv "$dest" "$bak"
    fi
    ln -s "$src" "$dest"
    echo "✅ Linked $dest -> $src"
}

os="$(uname -s)"
case "$os" in
Darwin)
    echo "ℹ️  Detected macOS"
    ;;
Linux)
    echo "ℹ️  Detected Linux"
    ;;
*)
    err "Unsupported OS: $os"
    exit 1
    ;;
esac

# Same file set on macOS and Linux: ~/.zshrc, ~/.profile, ~/.path.sh, ~/.tmux.conf, ~/.bashrc.
link_config "$CONFIGS_DIR/.zshrc" "$HOME/.zshrc"
link_config "$CONFIGS_DIR/.profile" "$HOME/.profile"
link_config "$CONFIGS_DIR/.path.sh" "$HOME/.path.sh"
link_config "$CONFIGS_DIR/.tmux.conf" "$HOME/.tmux.conf"
link_config "$CONFIGS_DIR/.bashrc" "$HOME/.bashrc"

# Ghostty reads $XDG_CONFIG_HOME/ghostty/config (default ~/.config/ghostty/config)
# on both macOS and Linux.
mkdir -p "$HOME/.config/ghostty"
link_config "$CONFIGS_DIR/ghostty/config" "$HOME/.config/ghostty/config"

# Herdr reads $XDG_CONFIG_HOME/herdr/config.toml (default ~/.config/herdr/config.toml)
# on both macOS and Linux.
mkdir -p "$HOME/.config/herdr"
link_config "$CONFIGS_DIR/herdr/config.toml" "$HOME/.config/herdr/config.toml"

echo "✅ Public configs installed"

# Guard against public <-> private installers calling each other back and
# forth forever (e.g. if the private installer is written symmetrically to
# also invoke its sibling repo's installer). Each installer is a separate
# process, so a plain "already ran" flag in this script's own scope can't
# stop the cycle — but an exported env var is inherited by every child
# process in the chain, so the second script to check it sees it set and
# stops the chain there.
if [ -n "${DOTFILES_CONFIGS_CHAIN_ACTIVE:-}" ]; then
    echo "ℹ️  Already inside a public/private install-configs chain — not invoking sibling installer again"
else
    private_installer="$PRIVATE_REPO_DIR/installers/install-configs.sh"
    if [ -x "$private_installer" ]; then
        echo "⏳ Installing private configs..."
        DOTFILES_CONFIGS_CHAIN_ACTIVE=1 "$private_installer"
    else
        echo "ℹ️  Private dotfiles repo not found at $PRIVATE_REPO_DIR — skipping private config install"
    fi
fi

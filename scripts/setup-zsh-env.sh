#!/usr/bin/env bash
# Sets up zsh + Oh My Zsh, tmux, and shell profile matching the standard dev environment.
# Supports Debian/Ubuntu, RedHat/Fedora/CentOS, and macOS (Homebrew).
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }
section() { echo -e "\n${BOLD}==> $*${NC}"; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    OS=macos
    PKG_INSTALL="brew install"
  elif command -v apt-get &>/dev/null; then
    OS=debian
    PKG_INSTALL="sudo apt-get install -y"
  elif command -v dnf &>/dev/null; then
    OS=redhat
    PKG_INSTALL="sudo dnf install -y"
  elif command -v yum &>/dev/null; then
    OS=redhat
    PKG_INSTALL="sudo yum install -y"
  else
    error "Unsupported OS. Exiting."
    exit 1
  fi
  info "Detected OS: $OS"
}

# ---------------------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------------------
pkg_install() {
  info "Installing: $*"
  $PKG_INSTALL "$@"
}

ensure_pkg() {
  local cmd=$1 pkg=${2:-$1}
  if ! command -v "$cmd" &>/dev/null; then
    pkg_install "$pkg"
  else
    info "$cmd already installed — skipping"
  fi
}

# ---------------------------------------------------------------------------
# Core packages
# ---------------------------------------------------------------------------
install_core_packages() {
  section "Installing core packages"
  if [[ "$OS" == "debian" ]]; then
    sudo apt-get update -qq
    pkg_install zsh tmux git curl wget make
  elif [[ "$OS" == "redhat" ]]; then
    pkg_install zsh tmux git curl wget make
  elif [[ "$OS" == "macos" ]]; then
    if ! command -v brew &>/dev/null; then
      error "Homebrew not found. Install it first: https://brew.sh"
      exit 1
    fi
    pkg_install zsh tmux git curl wget make
  fi
}

# ---------------------------------------------------------------------------
# Oh My Zsh
# ---------------------------------------------------------------------------
install_oh_my_zsh() {
  section "Oh My Zsh"
  if [[ -d "$HOME/.oh-my-zsh" ]]; then
    info "Oh My Zsh already installed — skipping"
    return
  fi
  info "Installing Oh My Zsh (non-interactive)..."
  RUNZSH=no CHSH=no sh -c \
    "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

# ---------------------------------------------------------------------------
# history-search-multi-word plugin (not bundled with OMZ)
# ---------------------------------------------------------------------------
install_hsmw_plugin() {
  section "history-search-multi-word plugin"
  local dest="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/history-search-multi-word"
  if [[ -d "$dest" ]]; then
    info "history-search-multi-word already present — skipping"
    return
  fi
  git clone --depth=1 \
    https://github.com/zdharma-continuum/history-search-multi-word.git \
    "$dest"
  info "Installed history-search-multi-word"
}

# ---------------------------------------------------------------------------
# Shell script lint/format tools, required by this repo's conventions
# ---------------------------------------------------------------------------
install_shell_lint_tools() {
  section "Shell lint/format tools (shellcheck, shfmt)"
  ensure_pkg shellcheck
  ensure_pkg shfmt
}

# ---------------------------------------------------------------------------
# Optional tools
# ---------------------------------------------------------------------------
install_direnv() {
  section "direnv"
  if command -v direnv &>/dev/null; then
    info "direnv already installed — skipping"
    return
  fi
  if [[ "$OS" == "macos" ]]; then
    pkg_install direnv
  elif [[ "$OS" == "debian" ]]; then
    pkg_install direnv
  elif [[ "$OS" == "redhat" ]]; then
    pkg_install direnv || {
      warn "direnv not in repos, installing via binary"
      local bin_dir="$HOME/.local/bin"
      mkdir -p "$bin_dir"
      curl -sfL https://direnv.net/install.sh | bash
    }
  fi
}

install_tfenv() {
  section "tfenv (Terraform version manager)"
  if [[ -d "$HOME/.tfenv" ]]; then
    info "tfenv already installed — skipping"
    return
  fi
  git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
  info "tfenv installed at ~/.tfenv"
}

install_ghostty() {
  section "Ghostty (terminal, configured to defer to Herdr — see configs/ghostty/config)"
  if [[ -d "/Applications/Ghostty.app" ]] || command -v ghostty &>/dev/null; then
    info "Ghostty already installed — skipping"
    return
  fi
  if [[ "$OS" == "macos" ]]; then
    brew install --cask ghostty
  else
    warn "No package for Ghostty on $OS in this script — install manually: https://ghostty.org/download"
  fi
}

install_herdr() {
  section "Herdr (agent-aware terminal workspace manager — see configs/herdr/config.toml)"
  if command -v herdr &>/dev/null; then
    info "herdr already installed — skipping"
    return
  fi
  if [[ "$OS" == "macos" ]]; then
    brew install herdr
  else
    curl -fsSL https://herdr.dev/install.sh | sh
  fi
}

install_krew() {
  section "kubectl krew plugin manager"
  if [[ -d "${KREW_ROOT:-$HOME/.krew}" ]]; then
    info "krew already installed — skipping"
    return
  fi
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found — skipping krew install. Install kubectl first."
    return
  fi
  (
    set -x
    cd "$(mktemp -d)"
    OS_KREW="$(uname | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/arm.*$/arm/' -e 's/aarch64/arm64/')"
    KREW_TMP="krew-${OS_KREW}_${ARCH}"
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW_TMP}.tar.gz"
    tar zxvf "${KREW_TMP}.tar.gz"
    ./"${KREW_TMP}" install krew
  )
}

# ---------------------------------------------------------------------------
# Configs (~/.zshrc, ~/.profile, ~/.tmux.conf, ~/.bashrc) and scripts
# (~/.local/bin) — delegates to the Makefile so this bootstrap script and
# `make install-configs` / `make install-local-bin` share one implementation.
# ---------------------------------------------------------------------------
install_configs_and_local_bin() {
  section "Configs (~/.zshrc, ~/.profile, ~/.tmux.conf, ~/.bashrc)"
  make -C "$DOTFILES_DIR" install-configs

  section "Scripts (~/.local/bin)"
  make -C "$DOTFILES_DIR" install-local-bin
}

# ---------------------------------------------------------------------------
# Change default shell to zsh
# ---------------------------------------------------------------------------
set_default_shell() {
  section "Default shell"
  local zsh_path
  zsh_path="$(command -v zsh)"
  if [[ "$SHELL" == "$zsh_path" ]]; then
    info "zsh is already the default shell"
    return
  fi
  if ! grep -qF "$zsh_path" /etc/shells; then
    echo "$zsh_path" | sudo tee -a /etc/shells > /dev/null
  fi
  chsh -s "$zsh_path"
  info "Default shell changed to zsh ($zsh_path). Re-login to take effect."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo -e "${BOLD}zsh environment setup${NC}"

  detect_os
  install_core_packages
  install_oh_my_zsh
  install_hsmw_plugin
  install_shell_lint_tools

  # Optional tools — comment out anything you don't need
  install_direnv
  install_tfenv
  install_krew
  install_ghostty
  install_herdr

  install_configs_and_local_bin
  set_default_shell

  echo
  info "Setup complete."
  warn "Remember to put secrets like GH_TOKEN in ~/.credentials (auto-sourced by .profile) if needed."
  warn "Re-open your terminal (or run: exec zsh) to load the new config."
}

main "$@"

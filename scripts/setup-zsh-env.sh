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

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*" >&2; }
section() { echo -e "\n${BOLD}==> $*${NC}"; }

# ---------------------------------------------------------------------------
# Interactive prompts for optional/impactful steps.
#
# Defaults to "yes" (unattended) when stdin isn't a terminal or -y/--yes was
# passed, so piped runs (curl | bash, CI, remote provisioning) keep working
# exactly as before without hanging on a prompt.
# ---------------------------------------------------------------------------
ASSUME_YES=0

confirm() {
    local prompt=$1
    if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]]; then
        return 0
    fi
    local reply
    read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt} [Y/n] ")" reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# maybe_run <prompt> <function> [args...] — ask before running an optional
# step; skips it (without tripping `set -e`) on "no".
maybe_run() {
    local prompt=$1
    shift
    if confirm "$prompt"; then
        "$@"
    else
        info "Skipping: $prompt"
    fi
}

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

install_fzf() {
    section "fzf (fuzzy finder)"
    if command -v fzf &>/dev/null; then
        info "fzf already installed — skipping"
        return
    fi
    if [[ "$OS" == "macos" || "$OS" == "debian" ]]; then
        pkg_install fzf
    elif [[ "$OS" == "redhat" ]]; then
        # fzf isn't in the base RHEL/CentOS repos (Fedora's dnf repos have
        # it, but RHEL/CentOS need EPEL) — fall back to the official
        # junegunn/fzf installer, which just fetches a prebuilt binary and
        # works on any distro without extra repos.
        pkg_install fzf || {
            warn "fzf not in repos (needs EPEL on RHEL/CentOS) — installing prebuilt binary from junegunn/fzf"
            local fzf_dir="$HOME/.fzf"
            if [[ ! -d "$fzf_dir" ]]; then
                git clone --depth=1 https://github.com/junegunn/fzf.git "$fzf_dir"
            fi
            "$fzf_dir/install" --bin --no-update-rc
            mkdir -p "$HOME/.local/bin"
            ln -sf "$fzf_dir/bin/fzf" "$HOME/.local/bin/fzf"
        }
    fi
}

install_jq() {
    section "jq (command-line JSON processor)"
    ensure_pkg jq
}

install_yq() {
    section "yq (command-line YAML/JSON processor — mikefarah/yq)"
    if command -v yq &>/dev/null; then
        info "yq already installed — skipping"
        return
    fi
    if [[ "$OS" == "macos" ]]; then
        pkg_install yq
        return
    fi
    # Debian/Ubuntu's "yq" apt package is a different, incompatible tool
    # (kislyuk/yq, a Python jq-wrapper with a different CLI) and RHEL/Fedora
    # ship no yq package at all — install the mikefarah/yq binary from
    # GitHub releases on both so behavior matches the Homebrew formula used
    # on macOS.
    (
        set -x
        cd "$(mktemp -d)"
        ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/')"
        # See install_stern for why this reads the release metadata from a
        # file rather than piping curl (or a captured variable) into grep.
        curl -fsSL -o release.json https://api.github.com/repos/mikefarah/yq/releases/latest
        VERSION="$(grep -m1 '"tag_name"' release.json | sed -E 's/.*"(v[^"]+)".*/\1/')"
        curl -fsSL "https://github.com/mikefarah/yq/releases/download/${VERSION}/yq_linux_${ARCH}" -o yq
        mkdir -p "$HOME/.local/bin"
        install -m 0755 yq "$HOME/.local/bin/yq"
    )
    info "yq installed at ~/.local/bin/yq"
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
    elif [[ "$OS" == "debian" ]] && grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
        # No official Ubuntu-repo package as of this writing (only Debian's
        # PPA-equivalent infra supports this, so it's Ubuntu-only, not
        # Debian-proper). mkasberg/ghostty-ubuntu publishes prebuilt .deb
        # builds via PPA for both amd64 and arm64; add-apt-repository is
        # idempotent (no-ops on a repeat run), so no extra guard is needed
        # beyond the "already installed" check above.
        ensure_pkg add-apt-repository software-properties-common
        sudo add-apt-repository -y ppa:mkasberg/ghostty-ubuntu
        sudo apt-get update -qq
        pkg_install ghostty
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

install_stern() {
    section "stern (multi-pod/container kubectl log tailing)"
    if command -v stern &>/dev/null; then
        info "stern already installed — skipping"
        return
    fi
    if [[ "$OS" == "macos" ]]; then
        pkg_install stern
        return
    fi
    # stern isn't packaged for Debian/Ubuntu or RHEL/CentOS (no apt/dnf/yum
    # package) — install the prebuilt binary from GitHub releases instead.
    (
        set -x
        cd "$(mktemp -d)"
        ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/')"
        # Fetch the release metadata to a file rather than piping curl (or
        # a captured variable — printf on a payload this size can still
        # block mid-write) into `grep -m1`: grep exiting on its first match
        # while a writer is still mid-flight trips a broken-pipe error
        # (curl exit 23, or SIGPIPE/exit 141 from printf) under
        # set -o pipefail. Reading a file grep already owns has no live
        # writer to race.
        curl -fsSL -o release.json https://api.github.com/repos/stern/stern/releases/latest
        VERSION="$(grep -m1 '"tag_name"' release.json | sed -E 's/.*"v([^"]+)".*/\1/')"
        TARBALL="stern_${VERSION}_linux_${ARCH}.tar.gz"
        curl -fsSLO "https://github.com/stern/stern/releases/download/v${VERSION}/${TARBALL}"
        tar xzf "${TARBALL}"
        mkdir -p "$HOME/.local/bin"
        install -m 0755 stern "$HOME/.local/bin/stern"
    )
    info "stern installed at ~/.local/bin/stern"
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
        echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    fi
    # Plain `chsh` always prompts for the *user's own* login password via PAM,
    # which hangs/fails with no TTY (e.g. a non-interactive `ssh host cmd`).
    # Running it as root (via passwordless sudo) satisfies pam_rootok instead,
    # skipping the password prompt entirely — fall back to plain chsh (normal
    # interactive prompt) when sudo isn't passwordless.
    if sudo -n true 2>/dev/null; then
        sudo chsh -s "$zsh_path" "$(whoami)"
    else
        chsh -s "$zsh_path"
    fi
    info "Default shell changed to zsh ($zsh_path). Re-login to take effect."
}

# ---------------------------------------------------------------------------
# macOS: disable automatic period substitution (double-space → ". ")
# ---------------------------------------------------------------------------
disable_auto_period_substitution() {
    section "macOS: disable automatic period substitution"
    defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
    info "Disabled automatic period substitution (NSGlobalDomain)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -y | --yes)
            ASSUME_YES=1
            shift
            ;;
        *)
            error "Unknown argument: $1"
            exit 1
            ;;
        esac
    done

    echo -e "${BOLD}zsh environment setup${NC}"

    detect_os
    install_core_packages
    install_oh_my_zsh
    install_hsmw_plugin
    install_shell_lint_tools

    # Optional tools — you'll be asked before each one (pass -y/--yes, or
    # run non-interactively, to accept all of them without prompting)
    maybe_run "Install direnv?" install_direnv
    maybe_run "Install fzf (fuzzy finder)?" install_fzf
    maybe_run "Install jq (JSON processor)?" install_jq
    maybe_run "Install yq (YAML/JSON processor)?" install_yq
    maybe_run "Install tfenv (Terraform version manager)?" install_tfenv
    maybe_run "Install krew (kubectl plugin manager)?" install_krew
    maybe_run "Install stern (kubectl log tailing)?" install_stern
    maybe_run "Install Ghostty (terminal)?" install_ghostty
    maybe_run "Install Herdr (terminal workspace manager)?" install_herdr

    install_configs_and_local_bin
    maybe_run "Change default shell to zsh?" set_default_shell
    if [[ "$OS" == "macos" ]]; then
        maybe_run "Disable automatic period substitution (double-space → \".\")?" disable_auto_period_substitution
    fi

    echo
    info "Setup complete."
    warn "Remember to put secrets like GH_TOKEN in ~/.credentials (auto-sourced by .profile) if needed."
    warn "Re-open your terminal (or run: exec zsh) to load the new config."
}

main "$@"

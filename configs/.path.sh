# ============================================================================
# PATH Configuration
# ============================================================================
# Kept separate from .profile and sourced early — before Oh My Zsh loads
# (see .zshrc) — because several bundled Oh My Zsh plugins (e.g. kubectl)
# silently no-op if their command isn't already on $PATH at load time:
#
#   if (( ! $+commands[kubectl] )); then return; fi
#
# Anything this repo's bootstrap script installs into ~/.local/bin,
# ~/.tfenv/bin, ~/.krew/bin, etc. needs to be on PATH before that check
# runs, not just by the time .profile is sourced later in .zshrc/.bashrc.
export PULUMI_CONFIG_PASSPHRASE=""
export PATH="$HOME/.tfenv/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
# $HOME-relative and existence-gated (not hardcoded to one user/machine), so
# these are safe no-ops on a machine that doesn't have the tool — including
# Linux, and including this repo's own private-repo counterpart being
# checked out for a different user. /opt/homebrew/bin also primes `brew`
# onto PATH before the `command -v brew` check later in .profile, which is
# what runs `brew shellenv` for the rest of Homebrew's own PATH/MANPATH
# setup — a genuinely clean shell has nothing under /opt/homebrew on PATH
# otherwise.
[[ -d "$HOME/.antigravity/antigravity/bin" ]] && export PATH="$HOME/.antigravity/antigravity/bin:$PATH"
[[ -d "$HOME/.opencode/bin" ]] && export PATH="$HOME/.opencode/bin:$PATH"
[[ -d /opt/homebrew/bin ]] && export PATH="$PATH:/opt/homebrew/bin"
[[ -d "$HOME/go/bin" ]] && export PATH="$PATH:$HOME/go/bin"

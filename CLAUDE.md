# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repository containing personal shell configurations, custom utility scripts, and installation automation. The repository manages both public and private dotfiles through a dual-repository structure.

## Repository Structure

The repository follows a two-tier architecture:

- `configs/` - Shell configurations, git configs, and tool settings
- `scripts/` - Custom utility scripts
- `skills/` - Agent skills in `SKILL.md` format (symlinked to `~/.claude/skills/` and `~/.agents/skills/`)
- `installers/` - Installation automation scripts (public repo only)

## Common Commands

### Installation

```bash
# Install all configs, scripts, and skills
make install-all

# Install only scripts to ~/.local/bin
make install-local-bin

# Install only config files, should be symlinked to target files
make install-configs

# Install only agent skills to ~/.claude/skills and ~/.agents/skills
make install-skills

# Download external skills (mattpocock, bastos) into skills/ — also run by 'make update'
make fetch-external-skills

# Pull latest from both public and private repos
make pull-master

# Update from upstream and reinstall (pull-master + fetch-external-skills + install-all)
make update

```

### How Installation Works

- **Scripts**: Symlinked from `scripts/` to `~/.local/bin/`
- **Configs**: Symlinked from `configs/` to home directory with OS-specific handling:
  - macOS: Uses `zshrc`, `bashrc`, `.profile` 
  - Linux: Uses `bashrc` `bashrc`, `.profile`
  - Both: `tmux.conf`
- **Skills**: Symlinked from `skills/` to `~/.claude/skills/` (Claude Code) and `~/.agents/skills/` (vendor-neutral path read by Codex, Gemini, opencode, and Copilot CLI)

## Shell Script Conventions

All shell scripts must follow these standards:

- **Shebang**: `#!/usr/bin/env bash`
- **Error handling**: `set -euo pipefail`
- **Formatting**: 4-space indentation via `shfmt -i 4`
- **Linting**: Must pass `shellcheck`
- **Shared utilities**: Source `util.sh` via `source "$(dirname "${BASH_SOURCE[0]}")"/util.sh` (provides `err()` for stderr output)
- **Output prefixes**: Use emoji for status messages: `❌` errors, `✅` success, `⏳` in-progress, `ℹ️` info
- **Validation**: After writing or modifying any script, always run `shellfmt.sh <script-path>` which runs both `shellcheck` and `shfmt`

## Key Architecture Patterns

### Symlink-Based Installation

All installers create symlinks (not copies) so that `git pull` immediately updates active configs and scripts. Installers use absolute paths via `realpath` or `pwd` for reliable symlinking and handle both public and private repositories in sequence. The shared symlink-loop logic (`link_tree`, `prune_dead_symlinks`) lives in `installers/lib.sh`, sourced by `install-local-bin.sh` and `install-skills.sh`.

### OS-Specific Config Handling

`installers/install-configs.sh` detects the OS and symlinks the appropriate files:

- macOS (Darwin): `~/.zshrc`, `~/.profile`, `~/.path.sh`, `~/.tmux.conf`, `~/.bashrc`
- Linux: `bashrc` → `~/.zshrc`, `~/.profile`, `~/.path.sh`, `~/.tmux.conf`, `~/.bashrc`
- Both: `~/.config/ghostty/config` — Ghostty terminal config set up to defer tab/window/split/workspace/agent management to [Herdr](https://herdr.dev) (installed via `brew install herdr`, config at `configs/herdr/config.toml`, prefix `ctrl+b`) by unbinding Ghostty's native Cmd-key chords so Herdr receives them directly via the Kitty keyboard protocol. See the comment headers in `configs/ghostty/config` and `configs/herdr/config.toml` for the approach and its source. `configs/.tmux.conf` still works standalone via its own `C-a` prefix but is no longer wired to these Cmd chords.

`installers/install-configs.sh` then invokes `install-configs.sh` to symlink the private configs (see the private repo's `CLAUDE.md`), guarded by `DOTFILES_CONFIGS_CHAIN_ACTIVE` against the two repos' installers calling each other back and forth if the private one is written symmetrically.

### Private Overlay Convention

`dotfiles-private` must **not** ship its own full `.zshrc`, `.bashrc`, or `.tmux.conf` — a second full file symlinked over this repo's copy just clobbers it (last symlink wins) instead of merging with it, and if both installers try to claim the same destination path it's also what turns the guard above from "prevents a loop" into "prevents a loop that would otherwise mask the clobbering." Private, machine- or identity-specific additions belong in optional fragment files that the public configs already source if present, so the public file stays the single owner of shared content:

- `~/.zshrc.private` — sourced from the end of `configs/.zshrc`
- `~/.bashrc.private` — sourced from the end of `configs/.bashrc`
- `~/.tmux.private.conf` — sourced from the end of `configs/.tmux.conf` via `source-file -q`
- `~/.credentials` — sourced from `configs/.profile` (secrets/env vars only; predates the convention above)

The private repo's `install-configs.sh` should symlink into these fragment paths, not into `~/.zshrc` / `~/.bashrc` / `~/.tmux.conf` directly.

### PATH Configuration

PATH additions (`~/.local/bin` for this repo's custom scripts, plus `~/.tfenv/bin`, `~/.krew/bin`, Homebrew, etc.) live in `configs/.path.sh`, not `configs/.profile`, and are sourced early — before Oh My Zsh loads in `.zshrc` — rather than at `.profile`'s later position. Several bundled Oh My Zsh plugins (e.g. `kubectl`) check `$+commands[...]` at load time and silently no-op, disabling all of their aliases, if the command isn't already on PATH yet; anything this repo's bootstrap script installs into `~/.local/bin` (kubectl, stern, yq, etc., on Linux) needs to be visible before that check runs. See the comment header in `configs/.path.sh` for the full explanation.

## Working with This Repository

### Adding New Scripts

1. Add executable script to `scripts/` (or `scripts/` for private scripts)
2. Ensure it follows the shell script conventions above (shebang, `set -euo pipefail`, etc.)
3. Run `shellfmt.sh <script-path>` to lint and format
4. Run `make install-local-bin` to symlink to `~/.local/bin`

### Modifying Existing Scripts

1. Edit the script in-place (symlinks mean changes are live immediately)
2. Run `shellfmt.sh <script-path>` to lint and format; fix any issues it reports

### Adding New Configs

1. Add config file to `configs/`
2. Add the symlink command to `installers/install-configs.sh` (follow existing patterns for OS-specific handling)
3. Run `make install-configs` to apply

### Modifying Existing Configs

Since configs are symlinked, editing the file in the repo immediately affects the active config. No reinstall needed unless adding new files.

## Commit Convention

This repository uses [Conventional Commits](https://www.conventionalcommits.org/) format. Scope should reflect the component being changed (e.g., `feat(litellm-proxy):`, `fix(shell):`, `docs(conventional-commits):`).

## Adding Agent Skills

Each skill is a subdirectory under `skills/` containing a `SKILL.md` file that defines the skill's behavior, triggers, and allowed tools. After adding or modifying skills, run `make install-skills` to symlink them to `~/.claude/skills/` (Claude Code) and `~/.agents/skills/` (the shared path read by Codex, Gemini, opencode, and Copilot CLI).

### Vendored external skills

Some skills are vendored (copied) from upstream repos rather than authored here. `installers/fetch-external-skills.sh` drives this via a pipe-delimited registry with two modes:

- **`fetch`**: clone the upstream repo, copy the skill directory flat into `skills/<name>/` (dropping any category nesting), and inject `metadata.author` into its `SKILL.md`, plus `license: <license>` if the registry entry has one (left empty when the upstream repo declares no license, rather than falsely claiming one). The `domain-modeling` skill is vendored this way from [`mattpocock/skills`](https://github.com/mattpocock/skills) (MIT). `pr-description` is vendored this way from [`hrishin/dotfiles`](https://github.com/hrishin/dotfiles/tree/master/skills/pr-description) — that repo has no declared license, so no `license:` field is injected for it.
- **`preserve`**: the skill is already vendored and locally customised, so the script verifies it exists and reports its source but never overwrites it. `conventional-commits` (originally from [`bastos/skills`](https://github.com/bastos/skills), vendored here via its customised fork at [`hrishin/dotfiles`](https://github.com/hrishin/dotfiles/tree/master/skills/conventional-commits)) uses this mode — it carries local edits (a macOS clipboard section, a `README.md`, and a `scripts/validate-commit-msg.sh` commitlint validator) that must not be clobbered.

Fetched skills are committed to the repo. Run `make fetch-external-skills` to refresh them; the script prints the upstream commit SHA(s), which should be recorded in the commit message. This script is intentionally NOT part of `install-all` (so plain installs stay offline), but `make update` does run it — after `pull-master` and before `install-all` — so a full update also refreshes the vendored skills. `install-skills.sh` then symlinks the vendored directories like any other local skill.

## Important Notes

- Installation scripts assume both repos are present and will attempt to process both
- Symlinks mean changes in this repo are immediately reflected in home directory
- The `make update` command pulls latest from both repositories, refreshes the vendored external skills, and reinstalls
- The `install-local-bin.sh` installer skips files listed in its `LOCAL_BIN_SKIP` array (e.g. `util.sh`, a shared library, and `git-autopush-post-commit`, a git hook script — neither belongs in PATH). If you add another library or hook file to `scripts/`, add its basename to `LOCAL_BIN_SKIP`
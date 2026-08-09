SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
INSTALLERS := $(REPO_ROOT)/installers

# Sibling checkout of the private dotfiles repo. Not configured yet —
# override on the command line (or export in your shell) once it exists:
#   make pull-master PRIVATE_REPO_DIR=~/code/dotfiles-private
#   make clone-private PRIVATE_REPO_URL=git@github.com:me/dotfiles-private.git
PRIVATE_REPO_DIR ?=
PRIVATE_REPO_URL ?=

.DEFAULT_GOAL := help

.PHONY: help bootstrap all install-all install-local-bin install-configs install-skills \
	fetch-external-skills pull-master update clone-private

help:
	@echo "Available targets:"
	@echo "  bootstrap              First-time host setup (installs zsh, Oh My Zsh, shellcheck/shfmt,"
	@echo "                         direnv/tfenv/krew, sets default shell; also runs install-configs"
	@echo "                         and install-local-bin). One-off — run once per new machine."
	@echo "  all                    Alias for install-all"
	@echo "  install-all            Install all configs, scripts, and skills"
	@echo "  install-local-bin      Install only scripts to ~/.local/bin"
	@echo "  install-configs        Install only config files, symlinked to target files"
	@echo "  install-skills         Install only agent skills to ~/.claude/skills and ~/.agents/skills"
	@echo "  fetch-external-skills  Download external skills (mattpocock, bastos) into skills/"
	@echo "  pull-master            Pull latest from both public and private repos"
	@echo "  update                 Update from upstream and reinstall (pull-master + fetch-external-skills + install-all)"
	@echo "  clone-private          Clone the private dotfiles repository"

# One-off, per-machine setup: installs system packages (zsh, tmux, Oh My
# Zsh, shellcheck/shfmt, direnv/tfenv/krew), changes the default shell, and
# runs install-configs + install-local-bin. Not part of install-all/update —
# those run frequently and stay lightweight (symlinks only, no package
# installs or shell changes).
bootstrap:
	@"$(REPO_ROOT)/scripts/setup-zsh-env.sh"

all: install-all

install-all: install-local-bin install-configs install-skills

install-local-bin:
	@"$(INSTALLERS)/install-local-bin.sh"

install-configs:
	@"$(INSTALLERS)/install-configs.sh"

install-skills:
	@"$(INSTALLERS)/install-skills.sh"

# Intentionally not part of install-all, so plain installs stay offline.
fetch-external-skills:
	@"$(INSTALLERS)/fetch-external-skills.sh"

pull-master:
	@echo "⏳ Pulling latest for public repo..."
	@git -C "$(REPO_ROOT)" pull
ifneq ($(strip $(PRIVATE_REPO_DIR)),)
	@echo "⏳ Pulling latest for private repo..."
	@git -C "$(PRIVATE_REPO_DIR)" pull
else
	@echo "ℹ️  PRIVATE_REPO_DIR not set — skipping private repo pull (run 'make clone-private' first, or pass PRIVATE_REPO_DIR=<path>)"
endif

update: pull-master fetch-external-skills install-all

clone-private:
ifeq ($(strip $(PRIVATE_REPO_URL)),)
	@echo "❌ PRIVATE_REPO_URL not set. Usage: make clone-private PRIVATE_REPO_URL=<git-url> [PRIVATE_REPO_DIR=<path>]"; exit 1
else
	@echo "⏳ Cloning private dotfiles repo..."
	@git clone "$(PRIVATE_REPO_URL)" "$(if $(strip $(PRIVATE_REPO_DIR)),$(PRIVATE_REPO_DIR),$(REPO_ROOT)/../dotfiles-private)"
endif

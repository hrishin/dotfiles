# dotfiles

Personal shell configuration and utility scripts.

## Quick setup on a new environment

```bash
git clone <this-repo-url> ~/code/dotfiles
cd ~/code/dotfiles
./scripts/setup-zsh-env.sh
```

The script bootstraps a full dev shell in one shot:

- Installs `zsh`, `tmux`, `git`, `curl`, `wget`, Oh My Zsh, and the `history-search-multi-word` plugin (Debian/Ubuntu, RedHat/Fedora/CentOS, and macOS via Homebrew are supported).
- Optionally installs `direnv`, `tfenv`, and `kubectl krew` (comment out the corresponding calls in `main()` in `scripts/setup-zsh-env.sh` if you don't want them).
- Copies this repo's `configs/.profile`, `configs/.zshrc`, and `configs/.tmux.conf` into `$HOME`, backing up any existing files first (`<file>.bak.<timestamp>`).
- Sets `zsh` as the default shell.

Because the script copies from this repo rather than embedding its own config, edit the files under `configs/` and re-run the script (or re-copy manually) to push changes to `$HOME`.

After it finishes:

1. Create `~/.credentials` with any secrets you need (e.g. `export GH_TOKEN=...`) — `.profile` sources it automatically if it exists, and it's untracked so it never ends up in this repo.
2. Re-open your terminal (or run `exec zsh`).

`configs/.bashrc` is also tracked here for reference but isn't copied by the script — symlink or copy it manually if you need it:

```bash
cp configs/.bashrc ~/.bashrc
```

## Contents

- `configs/` — shell and terminal multiplexer configuration (`.profile`, `.zshrc`, `.tmux.conf`, `.bashrc`).
- `scripts/` — dev environment bootstrap and standalone troubleshooting/utility scripts (AWS networking, container inspection, etc.). See `scripts/README.md` for details on each one.
- `install-minikube.sh` — installs KVM/libvirt and Docker CE on Debian/Ubuntu for running Minikube.

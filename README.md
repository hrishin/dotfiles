# dotfiles

Personal shell configuration, utility scripts, and Claude Code / agent skills, installed via a Makefile.

## Quick setup on a new machine

```bash
git clone <this-repo-url> ~/code/dotfiles
cd ~/code/dotfiles
make bootstrap
```

`make bootstrap` runs `scripts/setup-zsh-env.sh`, a one-time setup for a new machine:

- Installs `zsh`, `tmux`, `git`, `curl`, `wget`, `make`, Oh My Zsh, and the `history-search-multi-word` plugin (Debian/Ubuntu, RedHat/Fedora/CentOS, and macOS via Homebrew are supported).
- Installs `shellcheck` and `shfmt`, required by this repo's shell script conventions.
- Optionally installs `direnv`, `tfenv`, and `kubectl krew` (comment out the corresponding calls in `main()` in `scripts/setup-zsh-env.sh` if you don't want them).
- Runs `make install-configs` and `make install-local-bin` (see below).
- Sets `zsh` as the default shell.

Run it once per machine. Everything else below is a lightweight, repeatable Makefile target — safe to rerun anytime, no package installs or shell changes.

Because `$HOME` config files, `~/.local/bin` scripts, and installed skills are all symlinks into this repo, editing a file here takes effect immediately. You only need to rerun `make install-configs` / `install-local-bin` / `install-skills` when you add a *new* file that isn't linked yet, or on a new machine.

## Makefile targets

Run `make help` for the full list.

| Target | What it does |
| --- | --- |
| `make bootstrap` | One-time host setup (see above). The only target that installs system packages or changes your default shell. |
| `make install-all` (alias `make all`) | Symlinks configs, scripts, and skills — `install-local-bin` + `install-configs` + `install-skills`. |
| `make install-configs` | Symlinks `configs/.zshrc`, `.profile`, `.tmux.conf`, `.bashrc` into `$HOME`, backing up any existing real file first (`<file>.bak.<timestamp>`). |
| `make install-local-bin` | Symlinks `scripts/*` into `~/.local/bin`. |
| `make install-skills` | Symlinks `skills/*` into `~/.claude/skills` and `~/.agents/skills`. |
| `make fetch-external-skills` | Downloads the vendored external skills (from `mattpocock/skills`, `bastos/skills`) into `skills/`. Not part of `install-all`, so a plain install stays offline. |
| `make pull-master` | `git pull` on this repo, and on the private repo too if `PRIVATE_REPO_DIR` is set. |
| `make update` | `pull-master` + `fetch-external-skills` + `install-all` — pulls latest and reinstalls everything. |
| `make clone-private` | Clones the private dotfiles repo: `make clone-private PRIVATE_REPO_URL=<git-url> [PRIVATE_REPO_DIR=<path>]`. |

After `make bootstrap` finishes:

1. Create `~/.credentials` with any secrets you need (e.g. `export GH_TOKEN=...`) — `.profile` sources it automatically if it exists, and it's untracked so it never ends up in this repo.
2. Re-open your terminal (or run `exec zsh`).

## Contents

- `configs/` — shell and terminal multiplexer configuration (`.profile`, `.zshrc`, `.tmux.conf`, `.bashrc`).
- `scripts/` — dev environment bootstrap (`setup-zsh-env.sh`) and standalone troubleshooting/utility scripts (AWS networking, container inspection, etc.). See `scripts/README.md` for details on each one.
- `installers/` — the scripts behind the Makefile targets: symlinking configs/scripts/skills and fetching vendored skills.
- `skills/` — Claude Code / agent skills (`SKILL.md` format), some authored here and some vendored from upstream via `make fetch-external-skills`.
- `Makefile` — entry point for setup and installation; run `make help` for the full target list.

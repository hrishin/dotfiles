# dotfiles

Personal shell configuration, utility scripts, and Claude Code / agent skills, installed via a Makefile.

## Quick setup on a new machine

```bash
git clone https://github.com/hrishin/dotfiles.git ~/code/dotfiles
cd ~/code/dotfiles
bash scripts/setup-zsh-env.sh
```

Run the script directly, not via `make bootstrap`, for this very first invocation — a genuinely bare machine (a fresh cloud VM image, for instance) may not have `make` installed yet, and `make bootstrap` is itself just a one-line wrapper around this same script. Once it's finished (which includes installing `make`), `make bootstrap` and the script are equivalent — use whichever on any later machine that already has `make`.

`scripts/setup-zsh-env.sh` (equivalently, `make bootstrap`) is a one-time setup for a new machine:

- Installs `zsh`, `tmux`, `git`, `curl`, `wget`, `make`, Oh My Zsh, and the `history-search-multi-word` plugin (Debian/Ubuntu, RedHat/Fedora/CentOS, and macOS via Homebrew are supported).
- Installs `shellcheck` and `shfmt`, required by this repo's shell script conventions.
- Optionally installs `direnv`, `fzf`, `jq`, `yq`, `tfenv`, `kubectl`, `kubectx`/`kubens`, `kubectl krew`, `stern`, Ghostty, and Herdr — you're prompted `[Y/n]` before each one. Pass `-y`/`--yes` (or run the script non-interactively, e.g. piped through `curl | bash`) to accept all of them without prompting.
- Runs `make install-configs` and `make install-local-bin` (see below).
- Sets `zsh` as the default shell (also prompted).
- On macOS, optionally disables automatic period substitution (double-space → ". ").

Run it once per machine. Everything else below is a lightweight, repeatable Makefile target — safe to rerun anytime, no package installs or shell changes.

Because `$HOME` config files, `~/.local/bin` scripts, and installed skills are all symlinks into this repo, editing a file here takes effect immediately. You only need to rerun `make install-configs` / `install-local-bin` / `install-skills` when you add a *new* file that isn't linked yet, or on a new machine.

## Makefile targets

Run `make help` for the full list.

| Target | What it does |
| --- | --- |
| `make bootstrap` | One-time host setup (see above). The only target that installs system packages or changes your default shell. |
| `make install-all` (alias `make all`) | Symlinks configs, scripts, and skills — `install-local-bin` + `install-configs` + `install-skills`. |
| `make install-configs` | Symlinks `configs/.zshrc`, `.profile`, `.path.sh`, `.tmux.conf`, `.bashrc` into `$HOME`, backing up any existing real file first (`<file>.bak.<timestamp>`). |
| `make install-local-bin` | Symlinks `scripts/*` into `~/.local/bin`. |
| `make install-skills` | Symlinks `skills/*` into `~/.claude/skills` and `~/.agents/skills`. |
| `make fetch-external-skills` | Downloads the vendored external skills (from `mattpocock/skills`, `bastos/skills`) into `skills/`. Not part of `install-all`, so a plain install stays offline. |
| `make pull-master` | `git pull` on this repo, and on the private repo too if `PRIVATE_REPO_DIR` is set. |
| `make update` | `pull-master` + `fetch-external-skills` + `install-all` — pulls latest and reinstalls everything. |

After `make bootstrap` finishes:

1. Create `~/.credentials` with any secrets you need (e.g. `export GH_TOKEN=...`) — `.profile` sources it automatically if it exists, and it's untracked so it never ends up in this repo.
2. Re-open your terminal (or run `exec zsh`).

## Contents

- `configs/` — shell and terminal multiplexer configuration (`.profile`, `.zshrc`, `.path.sh`, `.tmux.conf`, `.bashrc`).
- `scripts/` — dev environment bootstrap (`setup-zsh-env.sh`) and standalone troubleshooting/utility scripts (AWS networking, container inspection, etc.). See `scripts/README.md` for details on each one.
- `installers/` — the scripts behind the Makefile targets: symlinking configs/scripts/skills and fetching vendored skills.
- `skills/` — Claude Code / agent skills (`SKILL.md` format), some authored here and some vendored from upstream via `make fetch-external-skills`.
- `images/` — container images built and published from this repo (e.g. a `kubectl debug` troubleshooting image). See `images/README.md`.
- `Makefile` — entry point for setup and installation; run `make help` for the full target list.

## Thanks

Thanks to [surajssd/dotfiles](https://github.com/surajssd/dotfiles) for the inspiration behind this repo.

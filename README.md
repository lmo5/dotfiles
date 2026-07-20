# dotfiles

Personal dotfiles managed with GNU `stow`. Each top-level directory is a stow
package mirroring the target layout under `$HOME`.

## Install

One line on a fresh machine (Ubuntu/Debian, Fedora, openSUSE, Arch, …):

```bash
curl -fsSL https://raw.githubusercontent.com/lmo5/dotfiles/master/setup.sh | bash
```

This clones the repo to `~/.dotfiles`, installs the tooling, backs up any existing
configs, and stows the packages. It is safe to re-run (idempotent).

The installer also offers an optional OpenAI Codex CLI setup. It installs
`@openai/codex` with npm and, in an interactive terminal, can start `codex --login`.
In unattended installs, sign in later with `codex --login`.

### Options

```bash
curl -fsSL .../setup.sh | bash -s -- --yes        # non-interactive, accept all prompts
curl -fsSL .../setup.sh | bash -s -- --minimal    # base deps + dotfiles only
./setup.sh --help                                 # full usage
```

| Flag | Effect |
|------|--------|
| `-y`, `--yes` | Assume "yes" to every optional prompt |
| `--minimal` | Skip optional/heavy tools |
| `--rollback` | Restore configs from a previous backup and unstow |
| `--no-clone` | Use the current directory as the repo |

Environment overrides: `DOTFILES_DIR`, `DOTFILES_YES=1`, `DOTFILES_MINIMAL=1`.

## Backup & rollback

Before stowing, every existing real config file is copied to a timestamped
directory under `~/.dotfiles-backups/<UTC-timestamp>/` with a `manifest.txt`
recording the files and stow packages touched.

To undo a run:

```bash
~/.dotfiles/setup.sh --rollback
```

It lists backups newest-first, unstows the recorded packages, and restores the
saved files. With `--yes` it uses the most recent backup automatically.

## Applying a single package manually

```bash
stow --no-folding -v -R -t "$HOME" <package>
```

Packages: `zsh`, `bash`, `shell`, `starship`, `bat`, `git`, `tmux`, `lazygit`,
`ghorg`, `claude`, `scripts`.

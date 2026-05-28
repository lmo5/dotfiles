# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Personal dotfiles managed with GNU `stow`. Each top-level directory is a stow package that mirrors the target directory structure relative to `$HOME`.

## Deploying / Applying Dotfiles

The primary setup entry point for a fresh Ubuntu/Debian machine is:

```bash
bash ubuntu-setup.sh
```

This script:
1. Installs system packages (zsh, stow, bat, tmux, kubectl, direnv, fzf, zoxide, starship, etc.)
2. Sets up Oh My Zsh with Powerlevel10k theme and plugins (zsh-autosuggestions, zsh-syntax-highlighting, zsh-completions)
3. Installs optional tools interactively (terragrunt, gum, glab, ghorg, difftastic)
4. Backs up existing configs to `~/.config_backup/`
5. Runs `stow` on all packages to symlink configs into `$HOME`

To apply a single stow package manually:

```bash
stow --no-folding -v -R -t "$HOME" <package>
```

Available packages: `zsh`, `bash`, `shell`, `starship`, `bat`, `git`, `tmux`, `kubie`, `ghorg`, `scripts`

## Repository Structure

Each directory is a stow package — files inside map directly to `$HOME`:

- `zsh/` → `.zshrc`, `.p10k.zsh` (Oh My Zsh + Powerlevel10k config)
- `bash/` → `.bashrc`, `.bash_logout`, `.profile`
- `shell/.shell/` → shared sourced files loaded by both bash and zsh:
  - `.aliases` — all shell aliases including an extensive kubectl alias set
  - `.functions` — shell functions (extract, ftext, cd override with auto-git-update, kubie-auth, etc.)
  - `.exports`, `.env`, `.external`, `.bash_completions`
- `git/` → `.gitconfig` (difftastic integration, rerere, pull.rebase=true, gitflow prefixes)
- `tmux/` → `.tmux.conf`
- `starship/` → `.config/starship.toml` and `mount-nfs.sh`
- `kubie/` → `kubie.yaml`
- `scripts/` → utility shell scripts (media organizers, deduplication, GitHub repo creator, etc.)
- `bat/`, `fonts/`, `ghorg/` — currently empty stow packages (reserved)

## Shell Architecture

`.zshrc` sources all files from `$HOME/.shell/.{exports,aliases,functions,external,zsh_completions,env}` before loading Oh My Zsh plugins. This means the `shell/` package must be stowed for zsh to function correctly.

The `cd` function in `.functions` is overridden to run `ls` and `auto_git_update` after every directory change. `auto_git_update` stashes uncommitted work, fetches, pulls, and restores the stash automatically when entering any git repo.

## Key Tools Expected to Be Present

The shell config assumes these are installed: `nvim`, `bat` (aliased as `cat`), `fzf`, `zoxide`, `starship`, `direnv`, `kubie`, `kubectl`, `trash-cli`, `lazygit`, `glab`, `gh`.

## Git Config Conventions

- `pull.rebase = true` — always rebase on pull
- `push.autoSetupRemote = true` — no need for `-u origin` on first push
- difftastic is configured as the external diff tool (`git ddiff`, `git dshow`, `git dlog` aliases)
- `rerere.enabled = true` — conflict resolutions are remembered
- Default branch: `master`

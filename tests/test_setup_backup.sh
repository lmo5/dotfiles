#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source <(sed '/^main "\$@"$/d' "$repo_dir/setup.sh")

actual="$(DOTFILES_DIR="$repo_dir" managed_configs | sort)"
expected="$(cd "$repo_dir" && git ls-files -- \
    zsh bash shell starship bat localbin git tmux lazygit ghorg claude wezterm \
    | sed 's@^[^/]*/@@' | sort)"

test "$actual" = "$expected"
printf '%s\n' "$actual" | grep -Fx '.shell/.env' >/dev/null
! printf '%s\n' "$actual" | grep -Fx '.shell/.exports.local' >/dev/null

temp_home="$(mktemp -d)"
trap 'rm -rf "$temp_home"' EXIT
HOME="$temp_home"
DOTFILES_DIR="$repo_dir"
BACKUP_ROOT="$HOME/.dotfiles-backups"
BACKUP_DIR=""
mkdir -p "$HOME/.shell"
printf 'existing value\n' > "$HOME/.shell/.env"

backup_configs
test ! -e "$HOME/.shell/.env"
tar -tzf "$BACKUP_DIR/files.tar.gz" | grep -Fx '.shell/.env' >/dev/null

(cd "$repo_dir" && stow --no-folding -t "$HOME" shell)
test -L "$HOME/.shell/.env"
test "$(readlink -f "$HOME/.shell/.env")" = "$repo_dir/shell/.shell/.env"

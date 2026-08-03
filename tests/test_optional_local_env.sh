#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

for file in bash/.bashrc bash/.profile zsh/.zshrc; do
    grep -Fx '[ -r "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"' "$repo_dir/$file" >/dev/null || exit 1
done

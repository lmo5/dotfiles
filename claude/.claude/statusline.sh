#!/usr/bin/env bash
# Claude Code status line — inspired by Powerlevel10k rainbow theme
# Left segments: user@host | cwd | git branch/status
# Right info: model | context usage | time

input=$(cat)

# --- Extract fields ---
user=$(whoami)
host=$(hostname -s)
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
[ -z "$cwd" ] && cwd=$(pwd)

model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Git info (skip optional locks)
git_branch=""
git_status=""
if git -C "$cwd" rev-parse --is-inside-work-tree --no-optional-locks 2>/dev/null | grep -q true; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  staged=$(git -C "$cwd" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  unstaged=$(git -C "$cwd" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  [ "$staged" -gt 0 ]    && git_status="${git_status}+${staged}"
  [ "$unstaged" -gt 0 ]  && git_status="${git_status} !${unstaged}"
  [ "$untracked" -gt 0 ] && git_status="${git_status} ?${untracked}"
  git_status=$(echo "$git_status" | sed 's/^ //')
fi

# Shorten home dir
display_cwd="${cwd/#$HOME/\~}"

# --- ANSI colors (will appear dimmed in status line) ---
RESET="\033[0m"
BOLD="\033[1m"
CYAN="\033[36m"
BLUE="\033[34m"
GREEN="\033[32m"
YELLOW="\033[33m"
MAGENTA="\033[35m"
DIM="\033[2m"

# --- Build output ---
# user@host
printf "${CYAN}${BOLD}%s@%s${RESET}" "$user" "$host"

# separator
printf "${DIM} | ${RESET}"

# cwd
printf "${BLUE}%s${RESET}" "$display_cwd"

# git
if [ -n "$git_branch" ]; then
  printf "${DIM} | ${RESET}"
  printf "${GREEN}%s${RESET}" "$git_branch"
  if [ -n "$git_status" ]; then
    printf " ${YELLOW}[%s]${RESET}" "$git_status"
  fi
fi

# model
if [ -n "$model" ]; then
  printf "${DIM} | ${RESET}"
  printf "${MAGENTA}%s${RESET}" "$model"
fi

# context usage
if [ -n "$used_pct" ]; then
  used_int=$(printf '%.0f' "$used_pct")
  printf "${DIM} | ${RESET}"
  if [ "$used_int" -ge 80 ]; then
    printf "\033[31mctx:%d%%${RESET}" "$used_int"
  elif [ "$used_int" -ge 50 ]; then
    printf "${YELLOW}ctx:%d%%${RESET}" "$used_int"
  else
    printf "${DIM}ctx:%d%%${RESET}" "$used_int"
  fi
fi

# time
printf "${DIM} | %s${RESET}" "$(date +%H:%M)"

printf "\n"

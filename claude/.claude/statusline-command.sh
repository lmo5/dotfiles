#!/bin/sh
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Unknown Model"')
effort=$(echo "$input" | jq -r '.effort.level // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
worktree=$(echo "$input" | jq -r '.worktree.name // empty')
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
current_dir=$(echo "$input" | jq -r '.worktree.original_cwd // empty')
rl_5h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | awk '{printf "%.0f", $1}')
rl_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
rl_7d_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

if [ -n "$used" ]; then
  used_display=$(printf "%.0f" "$used")
  usage_str="${used_display}%"
else
  usage_str="0%"
fi

if [ -n "$worktree" ]; then
  worktree_str="${worktree}"
else
  worktree_str="no worktree"
fi

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

git_str=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  staged=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  modified=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')

  git_str="$branch"
  [ "$staged" -gt 0 ] && git_str="${git_str} $(printf "${GREEN}+${staged}${RESET}")"
  [ "$modified" -gt 0 ] && git_str="${git_str} $(printf "${YELLOW}~${modified}${RESET}")"
else
  git_str="no branch"
fi


if [ -n "$total_cost" ]; then
  cost_display=$(awk "BEGIN { printf \"%.2f\", $total_cost }")
  block_str="\$${cost_display}"
else
  block_str="\$0.00"
fi

make_bar() {
  pct="$1"
  width=10
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  bar=""
  i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt $width ];  do bar="${bar}░"; i=$(( i + 1 )); done
  printf "%s" "$bar"
}

format_rl() {
  pct="$1"
  reset_ts="$2"
  label="$3"
  [ -z "$pct" ] && return
  if [ "$pct" -ge 90 ]; then color="$RED"
  elif [ "$pct" -ge 70 ]; then color="$YELLOW"
  else color="$GREEN"
  fi
  reset_time=$(date -r "$reset_ts" "+%-I:%M%p" 2>/dev/null || date -d "@$reset_ts" "+%-I:%M%p" 2>/dev/null)
  bar=$(make_bar "$pct")
  printf "${color}${label} ${bar} ${pct}%% resets ${reset_time}${RESET}"
}

rate_limit_str=""
rate_limit_str="${rate_limit_str}$(format_rl "$rl_5h_pct" "$rl_5h_reset" "5h")"
# rate_limit_str="${rate_limit_str}$(format_rl "$rl_7d_pct" "$rl_7d_reset" "7d")"

# caveman mode badge — merged from the caveman plugin statusline.
# Reads the plugin's flag file directly (hardened: no symlinks, capped, whitelisted)
# so it stays stable across plugin version bumps. Disable with CAVEMAN_STATUSLINE=0.
caveman_str=""
if [ "${CAVEMAN_STATUSLINE:-1}" != "0" ]; then
  cm_flag="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
  if [ -f "$cm_flag" ] && [ ! -L "$cm_flag" ]; then
    cm_mode=$(head -c 64 "$cm_flag" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    ORANGE='\033[38;5;172m'
    case "$cm_mode" in
      full)
        caveman_str=$(printf "${ORANGE}🗿${RESET}") ;;
      lite|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress)
        cm_suffix=$(printf '%s' "$cm_mode" | tr '[:lower:]' '[:upper:]')
        caveman_str=$(printf "${ORANGE}🗿%s${RESET}" "$cm_suffix") ;;
      *) ;;
    esac
    # Lifetime-savings suffix (e.g. ⛏ 12.4k), written by /caveman-stats. Opt out: CAVEMAN_STATUSLINE_SAVINGS=0.
    if [ -n "$caveman_str" ] && [ "${CAVEMAN_STATUSLINE_SAVINGS:-1}" != "0" ]; then
      cm_sav_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-statusline-suffix"
      if [ -f "$cm_sav_file" ] && [ ! -L "$cm_sav_file" ]; then
        cm_sav=$(head -c 64 "$cm_sav_file" 2>/dev/null | tr -d '\000-\037')
        [ -n "$cm_sav" ] && caveman_str="${caveman_str} $(printf "${ORANGE}%s${RESET}" "$cm_sav")"
      fi
    fi
  fi
fi
cm_part=""
# Prefix (front of bar) so the badge is never truncated off a narrow terminal.
[ -n "$caveman_str" ] && cm_part="${caveman_str} | "

repo_root=$(cd "$current_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$current_dir")
dir_display=$(basename "$repo_root")

if [ -n "$effort" ]; then
  printf "%s🤖 %s | 💪 %s | 🧠 %s | 💰 %s | ⏱️ %s\n📁 %s | 🌳 %s | 🌿 %s" "$cm_part" "$model" "$effort" "$usage_str" "$block_str" "$rate_limit_str" "$dir_display" "$worktree_str" "$git_str"
else
  printf "%s🤖 %s | 🧠 %s | 💰 %s | ⏱️ %s\n📁 %s | 🌳 %s | 🌿 %s" "$cm_part" "$model" "$usage_str" "$block_str" "$rate_limit_str" "$dir_display" "$worktree_str" "$git_str"
fi
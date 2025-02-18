#!/usr/bin/env bash
iatest=$(expr index "$-" i)
[[ $- == *i* ]] && stty -ixon
if [[ $iatest -gt 0 ]]; then
    bind "set completion-ignore-case on"
    bind "set show-all-if-ambiguous On"
    bind "set bell-style visible"
fi
shopt -s checkwinsize
shopt -s histappend
PROMPT_COMMAND='history -a'
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

# Ctrl+f binding
if [[ $- == *i* ]]; then
    bind '"\C-f":"zi\n"'
fi

# Source shell configuration files
for file in "$HOME/.shell/."{exports,aliases,functions,external,bash_completions,env}; do
    [ -r "$file" ] && source "$file"
done
     
eval "$(starship init bash)"
eval "$(zoxide init bash)"
eval "$(direnv hook bash)"

[ -f ~/.fzf.bash ] && source ~/.fzf.bash
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Generated for envman. Do not edit.
[ -s "$HOME/.config/envman/load.sh" ] && source "$HOME/.config/envman/load.sh"

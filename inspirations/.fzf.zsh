# Setup fzf
# ---------
if [[ ! "$PATH" == */home/ayoub/.fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/home/ayoub/.fzf/bin"
fi

source <(fzf --zsh)

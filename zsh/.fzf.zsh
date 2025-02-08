# Setup fzf
# ---------
if [[ ! "$PATH" == */home/ayoubel-moukhtafi/.fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/home/ayoubel-moukhtafi/.fzf/bin"
fi

source <(fzf --zsh)

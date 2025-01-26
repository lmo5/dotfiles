# Enable colors in the terminal
export CLICOLOR=1
export LSCOLORS=ExFxBxDxCxegedabagacad


# Prompt customization (minimal)
PROMPT='%n@%m %~ %# '

# History settings
HISTFILE=~/.zsh_history
SAVEHIST=-1
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Enable auto-cd (automatically cd into directories by typing their name)
setopt AUTO_CD

# Enable extended globbing (e.g., `ls **/*.txt`)
setopt EXTENDED_GLOB

# Enable correction for commands
setopt CORRECT
setopt CORRECT_ALL

source "$HOME/.shell/.exports"
source "$HOME/.shell/.aliases"
source "$HOME/.shell/.functions"
source "$HOME/.shell/.external"
source "$HOME/.shell/.zsh_completions"
source "$HOME/.shell/.env"
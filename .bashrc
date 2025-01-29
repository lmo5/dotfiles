# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# History management
# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# History settings
export HISTSIZE=-1
export HISTFILESIZE=-1
export HISTTIMEFORMAT="[%F %T] "


# append to the history file, don't overwrite it
shopt -s histappend

# Change the file location because certain bash sessions truncate .bash_history file upon close.
# http://superuser.com/questions/575479/bash-history-truncated-to-500-lines-on-each-login
export HISTFILE=~/.bash_eternal_history
# Force prompt to write history after every command.
# http://superuser.com/questions/20900/bash-history-loss
PROMPT_COMMAND="history -a; $PROMPT_COMMAND"

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize


# Prompt/PS1
if [ -f ${HOME}/.scripts/git-prompt.sh ]; then
  source ${HOME}/.scripts/git-prompt.sh
  export GIT_PS1_SHOWDIRTYSTATE="1"
  export PS1='\[\033[40m\]\[\033[34m\][\H:\[\033[36m\]\w\[\033[1m\]\[\033[37m\] $(kube_ps1)\[\033[0m\]\[\033[40m\]$(__git_ps1 "\[\033[35m\]{\[\033[32m\]%s\[\033[35m\]}")\[\033[34m\]][\t]$\[\033[0m\] '
else
  export PS1='\[\033[40m\]\[\033[34m\][\H:\[\033[36m\]\w\[\033[1m\]\[\033[37m\] $(kube_ps1)\[\033[0m\]\[\033[40m\]$(__git_ps1 "\[\033[35m\]{\[\033[32m\]%s\[\033[35m\]}")\[\033[34m\]][\t]$\[\033[0m\] '
fi
export LS_COLORS="di=34:ln=35:so=32:pi=33:ex=1;40:bd=34;40:cd=34;40:su=0;40:sg=0;40:tw=0;40:ow=0;40:"


# Kube PS1
if [ -f ${HOME}/.scripts/kube-ps1.sh ]; then
  source ${HOME}/.scripts/kube-ps1.sh
  export KUBE_PS1_SYMBOL_ENABLE=false
  export KUBE_PS1_NS_COLOR=yellow
fi


source "$HOME/.shell/.exports"
source "$HOME/.shell/.aliases"
source "$HOME/.shell/.functions"
source "$HOME/.shell/.external"
source "$HOME/.shell/.bash_completions"
source "$HOME/.shell/.env"

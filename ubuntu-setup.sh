#!/bin/bash -e

# Colors for output
RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'

# Check for sudo access
if ! groups | grep -q sudo; then
    echo "${RED}You need to be a member of the sudo group to run this script!${RC}"
    exit 1
fi

# Install dependencies
echo "${YELLOW}Installing dependencies...${RC}"
DEPENDENCIES='bash bash-completion tar bat tree multitail fastfetch wget unzip fontconfig neovim zsh stow curl git'
if ! sudo apt update && sudo apt install -y $DEPENDENCIES; then
    echo "${RED}Failed to install dependencies${RC}"
    exit 1
fi

# Install and configure bat (batcat)
echo "${YELLOW}Setting up bat (batcat)...${RC}"
if ! command -v bat >/dev/null; then
    # On Ubuntu/Debian, bat is installed as batcat
    if [ -f /usr/bin/batcat ]; then
        mkdir -p ~/.local/bin
        ln -s /usr/bin/batcat ~/.local/bin/bat
    else
        echo "${RED}bat installation not found${RC}"
        exit 1
    fi
fi

# Create bat config directory
mkdir -p ~/.config/bat

# Install kubectl
echo "${YELLOW}Installing kubectl...${RC}"
if ! command -v kubectl >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    sudo apt-get install -y kubectl
fi

# Install Devbox
echo "${YELLOW}Installing Devbox...${RC}"
if ! command -v devbox >/dev/null; then
    curl -fsSL https://get.jetpack.io/devbox | bash
fi

# Install MesloLGS Nerd Font
FONT_NAME="MesloLGS Nerd Font Mono"
FONT_DIR="$HOME/.local/share/fonts"

if ! fc-list :family | grep -iq "$FONT_NAME"; then
    echo "Installing font '$FONT_NAME'"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"
    TEMP_DIR=$(mktemp -d)
    
    if wget -q "$FONT_URL" -O "$TEMP_DIR/${FONT_NAME}.zip"; then
        mkdir -p "$FONT_DIR/$FONT_NAME"
        unzip -q "$TEMP_DIR/${FONT_NAME}.zip" -d "$TEMP_DIR"
        mv "$TEMP_DIR"/*.ttf "$FONT_DIR/$FONT_NAME/"
        fc-cache -f
        rm -rf "$TEMP_DIR"
        echo "'$FONT_NAME' installed successfully"
    else
        echo "${RED}Failed to download font${RC}"
    fi
fi

# Install Oh My Zsh
echo "${YELLOW}Installing Oh My Zsh...${RC}"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Install Powerlevel10k
echo "${YELLOW}Installing Powerlevel10k...${RC}"
if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
fi

# Install additional tools (Starship, fzf, zoxide)
if ! command -v starship >/dev/null; then
    echo "Installing Starship prompt..."
    curl -sS https://starship.rs/install.sh | sh
fi

if ! command -v fzf >/dev/null; then
    echo "Installing fzf..."
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
    ~/.fzf/install --all
fi

if ! command -v zoxide >/dev/null; then
    echo "Installing zoxide..."
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

# Backup existing configs that will be managed by stow
echo "${YELLOW}Backing up existing configurations...${RC}"
configs=(
    ".zshrc"
    ".p10k.zsh"
    ".config/starship.toml"
    ".config/fastfetch/config.jsonc"
    ".config/bat/config"
    ".bashrc"
    ".bash_logout"
    ".bash_profile"
    ".profile"
)

mkdir -p "$HOME/.config_backup"
for config in "${configs[@]}"; do
    if [ -f "$HOME/$config" ]; then
        echo "Backing up $config to $HOME/.config_backup/${config}.bak"
        mv "$HOME/$config" "$HOME/.config_backup/${config}.bak"
    fi
done

# Set up stow for different configuration groups
echo "${YELLOW}Setting up dotfiles with stow...${RC}"
# Define stow packages based on your directory structure
STOW_PACKAGES=(
    "zsh"      # Contains .zshrc, .p10k.zsh
    "bash"     # Contains bash-specific configs
    "shell"    # Contains shared shell configs
    "starship" # Contains starship configs
    "fonts"    # Contains font configs
    "bat"      # Contains bat configs
)

# Create necessary directories
mkdir -p "$HOME/.config"

# Stow each package
for package in "${STOW_PACKAGES[@]}"; do
    echo "Stowing $package configuration..."
    stow --no-folding -v -R -t "$HOME" "$package"
done

# Configure shell preference
read -p "Would you like to use zsh as your default shell? (y/n) " use_zsh
if [[ $use_zsh =~ ^[Yy]$ ]]; then
    if [ "$SHELL" != "$(which zsh)" ]; then
        echo "${YELLOW}Setting zsh as default shell...${RC}"
        chsh -s "$(which zsh)"
        echo "${GREEN}Please log out and log back in to use zsh as your default shell.${RC}"
        echo "${GREEN}After logging back in, run 'p10k configure' to set up your Powerlevel10k theme.${RC}"
    fi
else
    echo "${GREEN}Keeping bash as your default shell.${RC}"
    echo "${GREEN}Your bash configuration has been set up successfully.${RC}"
fi

echo "${GREEN}Setup complete!${RC}"
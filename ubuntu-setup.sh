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

# Install dependencies one by one to better handle errors
echo "${YELLOW}Installing dependencies...${RC}"
DEPENDENCIES=(
    bash
    bash-completion
    tar
    bat
    tree
    multitail
    fastfetch
    wget
    unzip
    fontconfig
    neovim
    zsh
    stow
    curl
    git
)

sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
# Update package list
echo "Updating package list..."
if ! sudo apt-get update; then
    echo "${RED}Failed to update package list${RC}"
    exit 1
fi

# Install each dependency
for dep in "${DEPENDENCIES[@]}"; do
    echo "Installing $dep..."
    if ! sudo apt-get install -y "$dep"; then
        echo "${RED}Failed to install $dep${RC}"
        exit 1
    fi
done

# Install and configure bat (batcat)
echo "${YELLOW}Setting up bat (batcat)...${RC}"
if ! command -v bat >/dev/null; then
    # On Ubuntu/Debian, bat is installed as batcat
    if [ -f /usr/bin/batcat ]; then
        # Check if the symbolic link already exists
        if [ ! -f ~/.local/bin/bat ]; then
            mkdir -p ~/.local/bin
            ln -s /usr/bin/batcat ~/.local/bin/bat
            echo "${GREEN}Successfully created the symbolic link for bat.${RC}"
        else
            echo "${YELLOW}Symbolic link for bat already exists.${RC}"
        fi
    else
        echo "${RED}bat installation not found at /usr/bin/batcat${RC}"
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


# Install kubectx and kubens
echo "${YELLOW}Installing kubectx and kubens...${RC}"
if ! command -v kubectx >/dev/null || ! command -v kubens >/dev/null; then
    sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
    sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
    sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
    echo "${GREEN}kubectx and kubens installed successfully.${RC}"
else
    echo "${YELLOW}kubectx and kubens are already installed.${RC}"
fi

# Install kube-ps1
echo "${YELLOW}Installing kube-ps1...${RC}"
if [ ! -d "$HOME/.kube-ps1" ]; then
    git clone https://github.com/jonmosco/kube-ps1.git "$HOME/.kube-ps1"
    echo "source $HOME/.kube-ps1/kube-ps1.sh" >> ~/.zshrc
    echo "${GREEN}kube-ps1 installed successfully.${RC}"
else
    echo "${YELLOW}kube-ps1 is already installed.${RC}"
fi

echo "${YELLOW}Installing k9s...${RC}"
if ! command -v k9s >/dev/null; then
    curl -sS https://webinstall.dev/k9s | bash
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

# Navigate to the oh-my-zsh custom plugins directory
cd $HOME/.oh-my-zsh/plugins

# Clone the zsh-autosuggestions repository
git clone https://github.com/zsh-users/zsh-autosuggestions.git
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git
git clone https://github.com/zsh-users/zsh-completions.git

cd -

# Install additional tools (Starship, fzf, zoxide)

if ! command -v fzf >/dev/null; then
   
    if [ ! -d "$HOME/.fzf" ]; then
        echo "Installing fzf..."
        git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
        ~/.fzf/install --all
    else
        echo "~/.fzf directory already exists. Skipping fzf installation."
    fi
fi

if ! command -v zoxide >/dev/null; then
    echo "Installing zoxide..."
    curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi
if ! command -v starship >/dev/null; then
    echo "Installing Starship prompt..."

    sh -c "$(curl -fsSL https://starship.rs/install.sh)" --yes
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

mkdir -p "$HOME/.config_backup/.config"
for config in "${configs[@]}"; do
    if [ -f "$HOME/$config" ]; then
        echo "Backing up $config to $HOME/${config}.bak"
        mv "$HOME/$config" "$HOME/${config}.bak"
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
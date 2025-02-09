#!/bin/bash
set -eo pipefail

# Colors for output
declare -r RC='\033[0m'
declare -r RED='\033[31m'
declare -r YELLOW='\033[33m'
declare -r GREEN='\033[32m'

# Error handling
trap 'echo "${RED}Error: Command failed at line $LINENO${RC}"; exit 1' ERR

# Helper functions
log() { echo -e "${2:-$YELLOW}$1${RC}"; }
error() { log "$1" "$RED" >&2; exit 1; }
success() { log "$1" "$GREEN"; }


setup_locales() {
    log "Setting up locales..."
    sudo locale-gen fr_FR.UTF-8
    sudo locale-gen en_US.UTF-8
    sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    
    # Export locale variables for current session
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
}

check_requirements() {
    if ! groups | grep -q sudo; then
        error "You need to be a member of the sudo group to run this script!"
    fi
}

install_package() {
    local package=$1
    log "Installing $package..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
        error "Failed to install $package"
    fi
}

setup_repositories() {
    log "Setting up package repositories..."
    
    # Create necessary directories
    sudo mkdir -p /etc/apt/keyrings
    
    # Setup Kubernetes repository
    if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
        log "Adding Kubernetes repository..."
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    fi
    
    # Setup Fastfetch repository
    if ! grep -q "fastfetch" /etc/apt/sources.list.d/* 2>/dev/null; then
        log "Adding Fastfetch repository..."
        sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch >/dev/null 2>&1
    fi
    
    # Update package lists
    log "Updating package lists..."
    sudo apt-get update -qq
}

install_dependencies() {
    log "Installing base dependencies..."
    
    local -a DEPENDENCIES=(
        bash bash-completion tar bat tree multitail fastfetch
        wget unzip fontconfig neovim zsh stow curl git
        kubectl apt-transport-https ca-certificates direnv
    )
    
    for package in "${DEPENDENCIES[@]}"; do
        install_package "$package"
    done
}

setup_bat() {
    log "Setting up bat..."
    if [ -f /usr/bin/batcat ] && [ ! -f ~/.local/bin/bat ]; then
        mkdir -p ~/.local/bin ~/.config/bat
        ln -sf /usr/bin/batcat ~/.local/bin/bat
    fi
}

setup_direnv() {
    log "Setting up direnv..."
    
    # Add direnv hook to shell configs
    local zsh_hook='eval "$(direnv hook zsh)"'
    local bash_hook='eval "$(direnv hook bash)"'
    
    # Add to .zshrc if exists and hook not already present
    if [ -f "$HOME/.zshrc" ] && ! grep -q "direnv hook zsh" "$HOME/.zshrc"; then
        echo "$zsh_hook" >> "$HOME/.zshrc"
    fi
    
    # Add to .bashrc if exists and hook not already present
    if [ -f "$HOME/.bashrc" ] && ! grep -q "direnv hook bash" "$HOME/.bashrc"; then
        echo "$bash_hook" >> "$HOME/.bashrc"
    fi
    
    # Create default .envrc template
    cat > "$HOME/.envrc.template" <<EOF
# Example .envrc file
# Uncomment and modify as needed

# Set local PATH additions
# PATH_add ./bin

# Load .env file
# dotenv

# Allow specific version of NodeJS
# use node 16

# Set environment variables
# export API_KEY="your-api-key"
# export DATABASE_URL="your-database-url"
EOF

    chmod 644 "$HOME/.envrc.template"
    success "direnv setup complete. Use .envrc.template as a reference for your projects."
}

install_kubernetes_tools() {
    log "Installing Kubernetes tools..."
    
    # Install kubectx and kubens
    if ! command -v kubectx >/dev/null; then
        log "Installing kubectx and kubens..."
        sudo git clone --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx
        sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
        sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
    fi
    
    # Install kube-ps1
    if [ ! -d "$HOME/.kube-ps1" ]; then
        log "Installing kube-ps1..."
        git clone --depth 1 https://github.com/jonmosco/kube-ps1.git "$HOME/.kube-ps1"
        echo "source $HOME/.kube-ps1/kube-ps1.sh" >> ~/.zshrc
    fi
    
    # Install k9s
    if ! command -v k9s >/dev/null; then
        log "Installing k9s..."
        curl -sS https://webinstall.dev/k9s | bash
    fi
}

install_devbox() {
    if ! command -v devbox >/dev/null; then
        log "Installing devbox..."
        curl -fsSL https://get.jetpack.io/devbox | bash
    fi
}

install_font() {
    local font_name="MesloLGS Nerd Font Mono"
    local font_dir="$HOME/.local/share/fonts"
    
    if ! fc-list :family | grep -iq "$font_name"; then
        log "Installing font '$font_name'..."
        local temp_dir=$(mktemp -d)
        wget -q "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip" -O "$temp_dir/font.zip"
        mkdir -p "$font_dir/$font_name"
        unzip -q "$temp_dir/font.zip" -d "$temp_dir"
        mv "$temp_dir"/*.ttf "$font_dir/$font_name/"
        fc-cache -f
        rm -rf "$temp_dir"
    fi
}

setup_shell_environment() {
    log "Setting up shell environment..."
    
    # Install Oh My Zsh
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log "Installing Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    
    # Install Powerlevel10k theme
    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
        log "Installing Powerlevel10k theme..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    fi
    
    # Install ZSH plugins
    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh}/plugins"
    
    if [ ! -d "$plugins_dir/zsh-autosuggestions" ]; then
        log "Installing zsh-autosuggestions..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions"
    fi
    
    if [ ! -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        log "Installing zsh-syntax-highlighting..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"
    fi
    
    if [ ! -d "$plugins_dir/zsh-completions" ]; then
        log "Installing zsh-completions..."
        git clone --depth=1 https://github.com/zsh-users/zsh-completions.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-completions"
    fi
}

install_additional_tools() {
    log "Installing additional tools..."
    
    if [ ! -d "$HOME/.fzf" ]; then
        log "Installing fzf..."
        git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
        ~/.fzf/install --all
    fi
    
    if ! command -v zoxide >/dev/null; then
        log "Installing zoxide..."
        curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    fi
    
    if ! command -v starship >/dev/null; then
        log "Installing starship..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y
    fi
}

backup_configs() {
    log "Backing up existing configurations..."
    local backup_dir="$HOME/.config_backup"
    mkdir -p "$backup_dir/.config"
    
    local -a configs=(
        ".zshrc" ".p10k.zsh" ".config/starship.toml"
        ".config/fastfetch/config.jsonc" ".config/bat/config"
        ".bashrc" ".bash_logout" ".bash_profile" ".profile"
    )
    
    for config in "${configs[@]}"; do
        if [ -f "$HOME/$config" ]; then
            log "Backing up $config..."
            mkdir -p "$(dirname "$backup_dir/$config")"
            mv "$HOME/$config" "$backup_dir/$config"
        fi
    done
}

setup_dotfiles() {
    log "Setting up dotfiles..."
    cd "$HOME/dotfiles" || error "Failed to change directory to dotfiles."
    
    local -a STOW_PACKAGES=(
        "zsh" "bash" "shell" "starship" "fonts" "bat"
    )
    
    for package in "${STOW_PACKAGES[@]}"; do
        if [ -d "$package" ]; then
            log "Setting up $package configuration..."
            stow --no-folding -v -R -t "$HOME" "$package" || {
                error "Failed to stow package $package. Please check the directory structure."
            }
        else
            log "Warning: Package directory $package not found, skipping..."
        fi
    done
}


configure_shell_preference() {
    read -p "Would you like to use zsh as your default shell? (y/n) " use_zsh
    if [[ $use_zsh =~ ^[Yy]$ ]] && [ "$SHELL" != "$(which zsh)" ]; then
        chsh -s "$(which zsh)"
        success "Please log out and log back in to use zsh as your default shell."
        success "After logging back in, run 'p10k configure' to set up your Powerlevel10k theme."
    else
        success "Keeping current shell as default."
    fi
}

main() {
    check_requirements
    setup_repositories
    install_dependencies
    setup_bat
    setup_direnv
    install_kubernetes_tools
    install_devbox
    install_font
    setup_shell_environment
    install_additional_tools
    backup_configs
    setup_dotfiles
    configure_shell_preference
    success "Setup complete!"
}

main "$@"
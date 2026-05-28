#!/bin/bash
set -eo pipefail

# Colors for output
declare -r RC='\033[0m'
declare -r RED='\033[31m'
declare -r YELLOW='\033[33m'
declare -r GREEN='\033[32m'

# Error handling
trap 'echo -e "${RED}Error: Command failed at line $LINENO${RC}"; exit 1' ERR

# Global package manager variables (set by checkEnv)
PACKAGER=""
SUDO_CMD=""
SUGROUP=""
AUR_HELPER=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()     { echo -e "${2:-$YELLOW}$1${RC}"; }
error()   { log "$1" "$RED" >&2; exit 1; }
success() { log "$1" "$GREEN"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Install a single package using the detected package manager
pkg_install() {
    local pkg="$1"
    log "Installing $pkg..."
    case "$PACKAGER" in
        pacman)       ${AUR_HELPER} --noconfirm -S "$pkg" ;;
        nala|apt)     ${SUDO_CMD} DEBIAN_FRONTEND=noninteractive ${PACKAGER} install -y "$pkg" ;;
        zypper)       ${SUDO_CMD} ${PACKAGER} install -n "$pkg" ;;
        dnf|yum)      ${SUDO_CMD} ${PACKAGER} install -y "$pkg" ;;
        emerge)       ${SUDO_CMD} ${PACKAGER} -v "$pkg" ;;
        xbps-install) ${SUDO_CMD} ${PACKAGER} -y "$pkg" ;;
        nix-env)      ${SUDO_CMD} ${PACKAGER} -iA "nixos.$pkg" ;;
        *)            ${SUDO_CMD} ${PACKAGER} install -y "$pkg" ;;
    esac
}

# ---------------------------------------------------------------------------
# Environment check
# ---------------------------------------------------------------------------

checkEnv() {
    log "Checking environment..."

    for req in curl groups sudo; do
        command_exists "$req" || error "Required tool not found: $req"
    done

    for pgm in nala apt dnf yum pacman zypper emerge xbps-install nix-env; do
        if command_exists "$pgm"; then
            PACKAGER="$pgm"
            log "Package manager: $pgm"
            break
        fi
    done
    [ -z "$PACKAGER" ] && error "Can't find a supported package manager"

    if command_exists sudo; then
        SUDO_CMD="sudo"
    elif command_exists doas && [ -f "/etc/doas.conf" ]; then
        SUDO_CMD="doas"
    else
        SUDO_CMD="su -c"
    fi
    log "Privilege escalation: $SUDO_CMD"

    for sug in wheel sudo root; do
        if groups | grep -q "$sug"; then
            SUGROUP="$sug"
            log "Superuser group: $SUGROUP"
            break
        fi
    done
    groups | grep -q "$SUGROUP" || error "You need to be a member of the sudo/wheel group to run this script!"

    # Set up AUR helper for Arch
    if [ "$PACKAGER" = "pacman" ]; then
        if ! command_exists yay && ! command_exists paru; then
            log "Installing yay as AUR helper..."
            ${SUDO_CMD} ${PACKAGER} --noconfirm -S base-devel
            cd /opt && ${SUDO_CMD} git clone https://aur.archlinux.org/yay-git.git
            ${SUDO_CMD} chown -R "${USER}:${USER}" /opt/yay-git
            cd /opt/yay-git && makepkg --noconfirm -si
            cd -
        fi
        command_exists yay && AUR_HELPER="yay" || AUR_HELPER="paru"
    fi
}

# ---------------------------------------------------------------------------
# Repository setup (external repos needed before installDepend)
# ---------------------------------------------------------------------------

setup_repositories() {
    log "Setting up package repositories..."
    case "$PACKAGER" in
        nala|apt)
            ${SUDO_CMD} mkdir -p /etc/apt/keyrings

            # Docker
            if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
                log "Adding Docker repository..."
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                    | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                ${SUDO_CMD} chmod a+r /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/docker.list > /dev/null
            fi

            # GitHub CLI
            if [ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]; then
                log "Adding GitHub CLI repository..."
                wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                    | ${SUDO_CMD} tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
                ${SUDO_CMD} chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            fi

            # HashiCorp (Vault)
            if [ ! -f /etc/apt/keyrings/hashicorp-archive-keyring.gpg ]; then
                log "Adding HashiCorp repository..."
                wget -qO- https://apt.releases.hashicorp.com/gpg \
                    | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
                echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
            fi

            # kubectl
            if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
                log "Adding Kubernetes repository..."
                curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
                    | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
                echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
            fi

            log "Updating package lists..."
            ${SUDO_CMD} apt-get update -qq
            ;;

        zypper)
            # Docker
            if ! ${SUDO_CMD} zypper repos 2>/dev/null | grep -q "docker-ce"; then
                log "Adding Docker repository..."
                ${SUDO_CMD} zypper addrepo https://download.docker.com/linux/opensuse/docker-ce.repo
            fi
            # GitHub CLI
            if ! ${SUDO_CMD} zypper repos 2>/dev/null | grep -q "gh-cli"; then
                log "Adding GitHub CLI repository..."
                ${SUDO_CMD} zypper addrepo https://cli.github.com/packages/rpm/gh-cli.repo
            fi
            # HashiCorp
            if ! ${SUDO_CMD} zypper repos 2>/dev/null | grep -q "hashicorp"; then
                log "Adding HashiCorp repository..."
                ${SUDO_CMD} zypper addrepo https://rpm.releases.hashicorp.com/opensuse/hashicorp.repo
            fi
            # kubectl
            if ! ${SUDO_CMD} zypper repos 2>/dev/null | grep -q "kubernetes"; then
                log "Adding Kubernetes repository..."
                ${SUDO_CMD} zypper addrepo https://pkgs.k8s.io/core:/stable:/v1.29/rpm/ kubernetes
            fi
            ${SUDO_CMD} zypper --gpg-auto-import-keys refresh
            ;;

        dnf|yum)
            command_exists dnf-plugins-core || ${SUDO_CMD} ${PACKAGER} install -y dnf-plugins-core
            # Docker
            ${SUDO_CMD} ${PACKAGER} config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || true
            # GitHub CLI
            ${SUDO_CMD} ${PACKAGER} config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || true
            # HashiCorp
            ${SUDO_CMD} ${PACKAGER} config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo 2>/dev/null || true
            ;;

        pacman)
            # AUR covers everything — no extra repos needed
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Base dependencies
# ---------------------------------------------------------------------------

installDepend() {
    log "Installing base dependencies..."
    case "$PACKAGER" in
        pacman)
            ${AUR_HELPER} --noconfirm -S \
                bash bash-completion tar bat tree multitail fastfetch \
                wget unzip fontconfig neovim zsh stow curl git \
                direnv tmux htop trash-restore jq kubectl
            ;;
        nala|apt)
            for pkg in \
                bash bash-completion tar bat tree multitail fastfetch \
                wget unzip fontconfig neovim zsh stow curl git \
                kubectl apt-transport-https ca-certificates \
                direnv tmux htop trash-cli jq; do
                pkg_install "$pkg"
            done
            ;;
        zypper)
            for pkg in \
                bash bash-completion tar bat tree multitail fastfetch \
                wget unzip fontconfig neovim zsh stow curl git \
                kubectl direnv tmux htop trash-cli jq; do
                pkg_install "$pkg"
            done
            ;;
        emerge)
            ${SUDO_CMD} ${PACKAGER} -v \
                app-shells/bash app-shells/bash-completion app-arch/tar \
                app-editors/neovim sys-apps/bat app-text/tree app-text/multitail \
                app-misc/fastfetch app-shells/zsh app-admin/stow \
                app-misc/jq app-shells/direnv app-misc/tmux
            ;;
        nix-env)
            ${SUDO_CMD} ${PACKAGER} -iA \
                nixos.bash nixos.bash-completion nixos.gnutar nixos.neovim \
                nixos.bat nixos.tree nixos.multitail nixos.fastfetch \
                nixos.zsh nixos.stow nixos.jq nixos.direnv nixos.tmux nixos.kubectl
            ;;
        dnf|yum)
            for pkg in \
                bash bash-completion tar bat tree multitail fastfetch \
                wget unzip fontconfig neovim zsh stow curl git \
                kubectl direnv tmux htop trash-cli jq; do
                pkg_install "$pkg"
            done
            ;;
        xbps-install)
            ${SUDO_CMD} ${PACKAGER} -y \
                bash bash-completion tar bat tree multitail fastfetch \
                wget unzip fontconfig neovim zsh stow curl git \
                direnv tmux htop jq
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Tool installers
# ---------------------------------------------------------------------------

setup_bat() {
    # Ubuntu ships the binary as `batcat`; create the expected symlink
    case "$PACKAGER" in
        nala|apt)
            if [ -f /usr/bin/batcat ] && [ ! -f "$HOME/.local/bin/bat" ]; then
                log "Creating bat symlink (Ubuntu batcat → bat)..."
                mkdir -p "$HOME/.local/bin" "$HOME/.config/bat"
                ln -sf /usr/bin/batcat "$HOME/.local/bin/bat"
            fi
            ;;
    esac
}

install_gh() {
    command_exists gh && { log "gh is already installed."; return; }
    log "Installing GitHub CLI (gh)..."
    case "$PACKAGER" in
        nala|apt|zypper|dnf|yum) pkg_install gh ;;
        pacman)  ${AUR_HELPER} --noconfirm -S github-cli ;;
        nix-env) ${SUDO_CMD} ${PACKAGER} -iA nixos.gh ;;
        *)       pkg_install gh ;;
    esac
    success "gh installed. Run 'gh auth login' to authenticate."
}

install_docker() {
    command_exists docker && { log "Docker is already installed."; return; }
    log "Installing Docker CE..."
    case "$PACKAGER" in
        nala|apt)
            ${SUDO_CMD} apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
                pkg_install "$pkg"
            done
            ;;
        zypper)
            pkg_install docker
            pkg_install docker-compose
            ${SUDO_CMD} systemctl enable --now docker
            ;;
        dnf|yum)
            ${SUDO_CMD} ${PACKAGER} remove -y docker docker-client docker-client-latest docker-common \
                docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
            for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
                pkg_install "$pkg"
            done
            ${SUDO_CMD} systemctl enable --now docker
            ;;
        pacman)
            ${AUR_HELPER} --noconfirm -S docker docker-compose
            ${SUDO_CMD} systemctl enable --now docker
            ;;
    esac
    ${SUDO_CMD} usermod -aG docker "$USER"
    success "Docker installed. Log out and back in to use Docker without sudo."
}

install_vault() {
    command_exists vault && { log "vault is already installed."; return; }
    log "Installing HashiCorp Vault..."
    case "$PACKAGER" in
        nala|apt|zypper|dnf|yum) pkg_install vault ;;
        pacman)  ${AUR_HELPER} --noconfirm -S vault ;;
        nix-env) ${SUDO_CMD} ${PACKAGER} -iA nixos.vault ;;
        *)       pkg_install vault ;;
    esac
    success "vault installed successfully."
}

install_claude() {
    command_exists claude && { log "Claude Code is already installed."; return; }
    log "Installing Claude Code..."
    if ! command_exists node; then
        log "Installing Node.js..."
        case "$PACKAGER" in
            nala|apt)
                curl -fsSL https://deb.nodesource.com/setup_lts.x | ${SUDO_CMD} -E bash - 2>/dev/null
                pkg_install nodejs
                ;;
            zypper)  pkg_install nodejs20 ;;
            dnf|yum) pkg_install nodejs ;;
            pacman)  ${AUR_HELPER} --noconfirm -S nodejs npm ;;
            nix-env) ${SUDO_CMD} ${PACKAGER} -iA nixos.nodejs ;;
        esac
    fi
    ${SUDO_CMD} npm install -g @anthropic-ai/claude-code
    command_exists claude \
        && success "Claude Code installed. Run 'claude' to authenticate. Plugins (superpowers, clangd-lsp) will auto-install on first run." \
        || error "Failed to install Claude Code."
}

install_stern() {
    command_exists stern && { log "stern is already installed."; return; }
    log "Installing stern..."
    local STERN_VERSION temp_dir
    STERN_VERSION=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    temp_dir=$(mktemp -d)
    curl -sL "https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_${STERN_VERSION#v}_linux_amd64.tar.gz" \
        | tar -xz -C "$temp_dir"
    ${SUDO_CMD} mv "$temp_dir/stern" /usr/local/bin/
    rm -rf "$temp_dir"
    success "stern installed successfully."
}

install_tfenv() {
    log "Installing tfenv..."
    if [ ! -d "$HOME/.tfenv" ]; then
        git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
        mkdir -p ~/.local/bin
        ln -sf ~/.tfenv/bin/* ~/.local/bin/
    fi
    if ! command_exists terraform; then
        log "Installing latest Terraform via tfenv..."
        ~/.tfenv/bin/tfenv install latest
        ~/.tfenv/bin/tfenv use latest
    fi
}

install_nerd_fonts() {
    local FONT_NAME="MesloLGS Nerd Font Mono"
    if fc-list :family | grep -iq "$FONT_NAME"; then
        log "Font '$FONT_NAME' is already installed."
        return
    fi
    log "Installing font '$FONT_NAME'..."
    local FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"
    local FONT_DIR="$HOME/.local/share/fonts"
    if wget -q --spider "$FONT_URL"; then
        local TEMP_DIR
        TEMP_DIR=$(mktemp -d)
        wget -q --show-progress "$FONT_URL" -O "$TEMP_DIR/${FONT_NAME}.zip"
        unzip -q "$TEMP_DIR/${FONT_NAME}.zip" -d "$TEMP_DIR"
        mkdir -p "$FONT_DIR/$FONT_NAME"
        mv "$TEMP_DIR"/*.ttf "$FONT_DIR/$FONT_NAME/"
        fc-cache -fv
        rm -rf "$TEMP_DIR"
        success "Font '$FONT_NAME' installed."
    else
        log "Font URL not accessible, skipping font install."
    fi
}

setup_shell_environment() {
    log "Setting up shell environment (Oh My Zsh + Powerlevel10k + plugins)..."

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    local p10k_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    [ -d "$p10k_dir" ] || git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"

    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh}/plugins"
    for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
        [ -d "$plugins_dir/$plugin" ] || \
            git clone --depth=1 "https://github.com/zsh-users/$plugin.git" "$plugins_dir/$plugin"
    done
}

install_additional_tools() {
    log "Installing fzf, zoxide, starship..."

    if [ ! -d "$HOME/.fzf" ]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
        ~/.fzf/install --all
    fi

    command_exists zoxide || curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

    command_exists starship || curl -sS https://starship.rs/install.sh | sh -s -- -y
}

install_lazygit() {
    command_exists lazygit && { log "lazygit is already installed."; return; }
    log "Installing lazygit..."
    case "$PACKAGER" in
        nala|apt)
            if ! grep -rq "ppa:lazygit" /etc/apt/sources.list.d/ 2>/dev/null; then
                ${SUDO_CMD} add-apt-repository -y ppa:lazygit-team/release
                ${SUDO_CMD} apt-get update -qq
            fi
            pkg_install lazygit
            ;;
        zypper) pkg_install lazygit ;;
        dnf|yum)
            ${SUDO_CMD} ${PACKAGER} copr enable -y atim/lazygit
            pkg_install lazygit
            ;;
        pacman) ${AUR_HELPER} --noconfirm -S lazygit ;;
        *)
            local LG_VERSION temp_dir
            LG_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
            temp_dir=$(mktemp -d)
            curl -sL "https://github.com/jesseduffield/lazygit/releases/download/${LG_VERSION}/lazygit_${LG_VERSION#v}_Linux_x86_64.tar.gz" \
                | tar -xz -C "$temp_dir"
            ${SUDO_CMD} mv "$temp_dir/lazygit" /usr/local/bin/
            rm -rf "$temp_dir"
            ;;
    esac
    success "lazygit installed successfully."
}

install_devbox() {
    if ! command_exists devbox; then
        log "Installing devbox..."
        curl -fsSL https://get.jetpack.io/devbox | bash
    fi
    for grp in nix-users nixbld; do
        getent group "$grp" > /dev/null 2>&1 && ${SUDO_CMD} usermod -aG "$grp" "$USER" || true
    done
    if [ -d /nix/var/nix/daemon-socket ]; then
        ${SUDO_CMD} chmod 666 /nix/var/nix/daemon-socket/socket
        ${SUDO_CMD} systemctl restart nix-daemon
    fi
}

install_ghorg() {
    command_exists ghorg && { log "ghorg is already installed."; return; }
    log "Installing ghorg..."
    local GHORG_VERSION temp_dir
    GHORG_VERSION=$(curl -s https://api.github.com/repos/gabrie30/ghorg/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    temp_dir=$(mktemp -d)
    curl -sL "https://github.com/gabrie30/ghorg/releases/download/${GHORG_VERSION}/ghorg_${GHORG_VERSION#v}_Linux_x86_64.tar.gz" \
        | tar -xz -C "$temp_dir"
    ${SUDO_CMD} mv "$temp_dir/ghorg" /usr/local/bin/
    chmod +x /usr/local/bin/ghorg
    rm -rf "$temp_dir"
    success "ghorg installed. Set GHORG_GITLAB_TOKEN to use with GitLab."
}

install_kubernetes_tools() {
    command_exists k9s || { log "Installing k9s..."; curl -sS https://webinstall.dev/k9s | bash; }
}

install_difftastic() {
    command_exists difft && { log "difftastic is already installed."; return; }
    log "Installing difftastic..."
    local DIFFT_VERSION temp_dir
    DIFFT_VERSION=$(curl -s https://api.github.com/repos/Wilfred/difftastic/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    temp_dir=$(mktemp -d)
    curl -sL "https://github.com/Wilfred/difftastic/releases/download/${DIFFT_VERSION}/difft-x86_64-unknown-linux-gnu.tar.gz" \
        | tar -xz -C "$temp_dir"
    ${SUDO_CMD} mv "$temp_dir/difft" /usr/local/bin/
    chmod +x /usr/local/bin/difft
    rm -rf "$temp_dir"
    success "difftastic installed."
}

install_optional_tools() {
    local install_terragrunt install_gum install_glab install_ghorg_opt install_difftastic_opt

    read -p "Would you like to install Terragrunt? (y/n) " install_terragrunt
    read -p "Would you like to install Gum? (y/n) " install_gum
    read -p "Would you like to install glab (GitLab CLI)? (y/n) " install_glab
    read -p "Would you like to install ghorg? (y/n) " install_ghorg_opt
    read -p "Would you like to install difftastic? (y/n) " install_difftastic_opt

    if [[ $install_terragrunt =~ ^[Yy]$ ]]; then
        log "Installing Terragrunt..."
        local TG_VERSION
        TG_VERSION=$(curl -s https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest | grep tag_name | cut -d '"' -f 4)
        mkdir -p ~/.local/bin
        wget -q "https://github.com/gruntwork-io/terragrunt/releases/download/${TG_VERSION}/terragrunt_linux_amd64" -O ~/.local/bin/terragrunt
        chmod +x ~/.local/bin/terragrunt
        success "Terragrunt installed."
    fi

    if [[ $install_gum =~ ^[Yy]$ ]]; then
        log "Installing Gum..."
        case "$PACKAGER" in
            nala|apt)
                ${SUDO_CMD} mkdir -p /etc/apt/keyrings
                curl -fsSL https://repo.charm.sh/apt/gpg.key | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/charm.gpg
                echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/charm.list > /dev/null
                ${SUDO_CMD} apt-get update -qq
                pkg_install gum
                ;;
            zypper)
                ${SUDO_CMD} zypper addrepo https://repo.charm.sh/rpm/charm.repo 2>/dev/null || true
                ${SUDO_CMD} zypper --gpg-auto-import-keys refresh
                pkg_install gum
                ;;
            dnf|yum)
                ${SUDO_CMD} ${PACKAGER} config-manager --add-repo https://repo.charm.sh/rpm/charm.repo 2>/dev/null || true
                pkg_install gum
                ;;
            pacman) ${AUR_HELPER} --noconfirm -S gum ;;
        esac
        success "gum installed."
    fi

    if [[ $install_glab =~ ^[Yy]$ ]]; then
        log "Installing glab..."
        case "$PACKAGER" in
            nala|apt)
                if [ ! -f /etc/apt/keyrings/gitlab-cli.gpg ]; then
                    curl -fsSL https://gitlab.com/gitlab-org/cli/-/raw/main/support/deb.gpg.key \
                        | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/gitlab-cli.gpg
                    echo "deb [signed-by=/etc/apt/keyrings/gitlab-cli.gpg] https://gitlab.com/gitlab-org/cli/uploads/gpg/deb stable main" \
                        | ${SUDO_CMD} tee /etc/apt/sources.list.d/glab.list > /dev/null
                    ${SUDO_CMD} apt-get update -qq
                fi
                pkg_install glab
                ;;
            zypper) pkg_install glab ;;
            dnf|yum) pkg_install glab ;;
            pacman) ${AUR_HELPER} --noconfirm -S gitlab-glab-bin ;;
        esac
        success "glab installed."
    fi

    [[ $install_ghorg_opt =~ ^[Yy]$ ]]       && install_ghorg
    [[ $install_difftastic_opt =~ ^[Yy]$ ]]  && install_difftastic
}

# ---------------------------------------------------------------------------
# Shell and dotfile setup
# ---------------------------------------------------------------------------

setup_direnv() {
    log "Setting up direnv hooks..."
    for rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$rc_file" ] || continue
        grep -q "direnv hook" "$rc_file" || \
            echo 'eval "$(direnv hook $(basename "$SHELL"))"' >> "$rc_file"
        grep -q 'HOME/.local/bin' "$rc_file" || \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc_file"
    done
}

backup_configs() {
    log "Backing up existing configurations..."
    local backup_dir="$HOME/.config_backup"
    mkdir -p "$backup_dir/.config"

    local configs=(
        ".zshrc" ".p10k.zsh" ".config/starship.toml"
        ".config/fastfetch/config.jsonc" ".config/bat/config"
        ".bashrc" ".bash_logout" ".bash_profile" ".profile"
        ".config/lazygit/config.yml" ".gitconfig"
        ".claude/settings.json" ".claude/statusline-command.sh" ".claude/statusline.sh"
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
    log "Setting up dotfiles via stow..."
    # Resolve the directory that contains this script
    local dotfiles_dir
    dotfiles_dir="$(cd "$(dirname "$0")" && pwd)"
    cd "$dotfiles_dir"
    mkdir -p localbin

    local packages=(zsh bash shell starship bat localbin git tmux lazygit ghorg claude)
    for pkg in "${packages[@]}"; do
        if [ -d "$pkg" ]; then
            log "Stowing $pkg..."
            stow --no-folding -v -R -t "$HOME" "$pkg" || error "Failed to stow $pkg"
        else
            log "Warning: package directory '$pkg' not found, skipping."
        fi
    done
}

configure_shell_preference() {
    read -p "Would you like to use zsh as your default shell? (y/n) " use_zsh
    if [[ $use_zsh =~ ^[Yy]$ ]] && [ "$SHELL" != "$(command -v zsh)" ]; then
        chsh -s "$(command -v zsh)"
        success "Log out and back in to use zsh. Then run 'p10k configure' to set up the theme."
    else
        success "Keeping current shell."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    checkEnv
    setup_repositories
    installDepend
    setup_bat
    install_gh
    install_docker
    install_vault
    install_devbox
    install_stern
    install_tfenv
    install_nerd_fonts
    setup_shell_environment
    install_additional_tools
    install_lazygit
    install_claude
    install_kubernetes_tools
    setup_direnv
    install_optional_tools
    backup_configs
    setup_dotfiles
    configure_shell_preference
    success "Setup complete! Restart your shell to see the changes."
}

main "$@"

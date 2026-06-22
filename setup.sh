#!/bin/bash
# Personal dotfiles installer — safe to run via:
#   curl -fsSL https://raw.githubusercontent.com/lmo5/dotfiles/master/setup.sh | bash
#
# set -e is intentionally NOT used: this is a long installer and a single failing
# optional tool must not abort the whole run. Critical steps fail loudly via error().
set -uo pipefail

# Colors for output
declare -r RC='\033[0m'
declare -r RED='\033[31m'
declare -r YELLOW='\033[33m'
declare -r GREEN='\033[32m'
declare -r BLUE='\033[34m'
declare -r BOLD='\033[1m'

# ---------------------------------------------------------------------------
# Refuse to run as root.
# This installer sets up a *user's* dotfiles and home directory; it escalates
# with sudo only for the few steps that genuinely need it. Running the whole
# thing as root creates root-owned files in $HOME and installs tools (e.g. npm
# globals) into root-owned locations, which breaks things like auto-updates.
# Set DOTFILES_ALLOW_ROOT=1 to override (e.g. inside a root-only container).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ] && [ -z "${DOTFILES_ALLOW_ROOT:-}" ]; then
    printf '%b\n' "${RED}${BOLD}Refusing to run as root.${RC}" >&2
    printf '%b\n' "${YELLOW}Run this installer as your normal user — it calls sudo itself when needed:${RC}" >&2
    printf '%b\n' "${YELLOW}    ./setup.sh          ${RED}# not  sudo ./setup.sh${RC}" >&2
    printf '%b\n' "${YELLOW}If you really must run as root (e.g. a root-only container), set DOTFILES_ALLOW_ROOT=1.${RC}" >&2
    exit 1
fi

# Where the dotfiles repo lives / will be cloned to (override with DOTFILES_DIR env)
REPO_URL="https://github.com/lmo5/dotfiles.git"
CLONE_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"

# Global package manager variables (set by detect_packager)
PACKAGER=""
SUDO_CMD=""
SUGROUP=""
AUR_HELPER=""

# Behavior flags (set by parse_args / env)
DOTFILES_DIR="${DOTFILES_DIR:-}"
DOTFILES_YES="${DOTFILES_YES:-}"
DOTFILES_MINIMAL="${DOTFILES_MINIMAL:-}"
DO_ROLLBACK=""
NO_CLONE=""

# Step tracking for the progress UX / final summary
STEP=0
TOTAL=0
STEPS_OK=()
STEPS_FAILED=()
STEPS_SKIPPED=()

# Backup destination for this run (set by backup_configs)
BACKUP_ROOT="$HOME/.dotfiles-backups"
BACKUP_DIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()     { echo -e "${2:-$YELLOW}$1${RC}"; }
error()   { log "$1" "$RED" >&2; exit 1; }
success() { log "$1" "$GREEN"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# True only if /dev/tty can actually be opened for reading (works under curl|bash
# where stdin is the pipe, but false in cron / no controlling terminal).
has_tty() { (exec < /dev/tty) 2>/dev/null; }

# Install a single package using the detected package manager
pkg_install() {
    local pkg="$1"
    log "Installing $pkg..."
    case "$PACKAGER" in
        pacman)       ${AUR_HELPER} --noconfirm -S "$pkg" ;;
        nala|apt)     ${SUDO_CMD} DEBIAN_FRONTEND=noninteractive ${PACKAGER} install -y "$pkg" ;;
        zypper)       ${SUDO_CMD} ${PACKAGER} install -y "$pkg" ;;
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

# Detect package manager + privilege escalation command. Safe to call standalone
# (used by both bootstrap's ensure_git and checkEnv).
detect_packager() {
    [ -n "$PACKAGER" ] && return 0

    for pgm in nala apt dnf yum pacman zypper emerge xbps-install nix-env; do
        if command_exists "$pgm"; then
            PACKAGER="$pgm"
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

    # Resolve an AUR helper name for Arch (full bootstrap handled in checkEnv)
    if [ "$PACKAGER" = "pacman" ]; then
        command_exists yay && AUR_HELPER="yay"
        command_exists paru && AUR_HELPER="paru"
    fi
}

# Ensure git is available before we try to clone the repo (curl|bash path).
ensure_git() {
    command_exists git && return 0
    log "git not found — installing it first..."
    detect_packager
    [ "$PACKAGER" = "pacman" ] && [ -z "$AUR_HELPER" ] \
        && ${SUDO_CMD} pacman --noconfirm -S git \
        || pkg_install git
    command_exists git || error "Failed to install git, which is required to clone the dotfiles."
}

checkEnv() {
    log "Checking environment..."

    for req in curl groups sudo; do
        command_exists "$req" || error "Required tool not found: $req"
    done

    detect_packager
    log "Package manager: $PACKAGER"
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
            cd - || true
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
                bash bash-completion tar bat tree multitail \
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

install_fastfetch() {
    command_exists fastfetch && { log "fastfetch is already installed."; return; }
    log "Installing fastfetch..."
    case "$PACKAGER" in
        nala|apt)
            # Ubuntu/Debian don't ship fastfetch in their default repos —
            # grab the latest .deb release directly from GitHub.
            local url deb
            url=$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
                | grep -o '"browser_download_url": *"[^"]*linux-amd64\.deb"' \
                | head -1 | cut -d'"' -f4)
            [ -n "$url" ] || { log "Could not resolve fastfetch release URL; skipping."; return 1; }
            deb="$(mktemp --suffix=.deb)"
            curl -fsSL "$url" -o "$deb" || { rm -f "$deb"; error "Failed to download fastfetch from $url"; }
            ${SUDO_CMD} apt-get install -y "$deb"
            rm -f "$deb"
            ;;
        *) pkg_install fastfetch ;;
    esac
    command_exists fastfetch && success "fastfetch installed." || error "Failed to install fastfetch."
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
    if ! prompt_yn "Install Nerd Font '$FONT_NAME' (needed for Powerlevel10k icons)?" y; then
        log "Skipping Nerd Font install — leaving fonts untouched."
        return 2   # signals run_step to record this as skipped, not done
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

install_ghq() {
    command_exists ghq && { log "ghq is already installed."; return; }
    log "Installing ghq..."
    local GHQ_VERSION temp_dir
    GHQ_VERSION=$(curl -s https://api.github.com/repos/x-motemen/ghq/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    temp_dir=$(mktemp -d)
    curl -sL "https://github.com/x-motemen/ghq/releases/download/${GHQ_VERSION}/ghq_linux_amd64.zip" \
        -o "$temp_dir/ghq.zip"
    unzip -q "$temp_dir/ghq.zip" -d "$temp_dir"
    ${SUDO_CMD} mv "$temp_dir/ghq_linux_amd64/ghq" /usr/local/bin/ghq
    ${SUDO_CMD} chmod +x /usr/local/bin/ghq
    rm -rf "$temp_dir"
    success "ghq installed. Repos live at ~/repos/<host>/<owner>/<repo> (ghq.root set in gitconfig)."
}

install_syncthing() {
    command_exists syncthing && { log "syncthing is already installed."; return; }
    log "Installing Syncthing..."
    case "$PACKAGER" in
        nala|apt)
            if [ ! -f /etc/apt/keyrings/syncthing-archive-keyring.gpg ]; then
                curl -s https://syncthing.net/release-key.gpg \
                    | ${SUDO_CMD} gpg --dearmor -o /etc/apt/keyrings/syncthing-archive-keyring.gpg
                echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] \
https://apt.syncthing.net/ syncthing stable" \
                    | ${SUDO_CMD} tee /etc/apt/sources.list.d/syncthing.list > /dev/null
                ${SUDO_CMD} apt-get update -qq
            fi
            pkg_install syncthing
            ;;
        zypper)   pkg_install syncthing ;;
        dnf|yum)  pkg_install syncthing ;;
        pacman)   ${AUR_HELPER} --noconfirm -S syncthing ;;
        nix-env)  ${SUDO_CMD} ${PACKAGER} -iA nixos.syncthing ;;
        *)        pkg_install syncthing ;;
    esac
    # Enable user service; may be a no-op if not in a user session
    systemctl --user enable --now syncthing 2>/dev/null \
        || log "  Note: could not enable syncthing user service — run 'systemctl --user enable --now syncthing' after login."
    success "Syncthing installed. Web UI: http://127.0.0.1:8384"
}

setup_syncthing_laptop() {
    local script="$DOTFILES_DIR/syncthing/setup-syncthing.sh"
    if [ ! -f "$script" ]; then
        log "syncthing/setup-syncthing.sh not found — skipping."
        return
    fi
    bash "$script"
}

install_ente_auth() {
    { command_exists enteauth || command_exists ente-auth; } && { log "Ente Auth is already installed."; return; }
    [ -f "$HOME/.local/bin/ente-auth.AppImage" ] && { log "Ente Auth is already installed."; return; }
    log "Installing Ente Auth..."
    local ENTE_TAG temp_dir base_url
    ENTE_TAG=$(curl -s "https://api.github.com/repos/ente-io/ente/releases?per_page=100" \
        | grep '"tag_name"' | grep -m1 'auth-v4' | cut -d'"' -f4)
    [ -z "$ENTE_TAG" ] && { log "Could not resolve an Ente Auth (auth-v4) release; skipping."; return; }
    base_url="https://github.com/ente-io/ente/releases/download/${ENTE_TAG}"
    temp_dir=$(mktemp -d)
    case "$PACKAGER" in
        nala|apt)
            curl -fsSL "${base_url}/ente-${ENTE_TAG}-x86_64.deb" -o "$temp_dir/ente-auth.deb"
            ${SUDO_CMD} DEBIAN_FRONTEND=noninteractive ${PACKAGER} install -y "$temp_dir/ente-auth.deb"
            ;;
        zypper)
            curl -fsSL "${base_url}/ente-${ENTE_TAG}-x86_64.rpm" -o "$temp_dir/ente-auth.rpm"
            # The vendor rpm is Fedora-style: its 'sqlite-libs' dependency name does
            # not exist on openSUSE (the library ships as libsqlite3-0), so a plain
            # zypper install fails to resolve. Pull the real runtime libs first, then
            # install ignoring the unresolvable dependency names. The binary links
            # the Ayatana appindicator fork (libayatana-appindicator3.so.1), not the
            # old libappindicator3, so it fails to start without that exact library.
            ${SUDO_CMD} zypper install -y libayatana-appindicator3-1 libsecret-1-0 libsqlite3-0 polkit
            ${SUDO_CMD} rpm -i --nodeps --replacepkgs "$temp_dir/ente-auth.rpm"
            ;;
        dnf|yum)
            curl -fsSL "${base_url}/ente-${ENTE_TAG}-x86_64.rpm" -o "$temp_dir/ente-auth.rpm"
            ${SUDO_CMD} ${PACKAGER} install -y "$temp_dir/ente-auth.rpm"
            ;;
        *)
            curl -fsSL "${base_url}/ente-${ENTE_TAG}-x86_64.AppImage" -o "$temp_dir/ente-auth.AppImage"
            install -Dm755 "$temp_dir/ente-auth.AppImage" "$HOME/.local/bin/ente-auth.AppImage"
            ln -sf "$HOME/.local/bin/ente-auth.AppImage" "$HOME/.local/bin/ente-auth"
            mkdir -p "$HOME/.local/share/applications"
            cat > "$HOME/.local/share/applications/ente-auth.desktop" <<EODESKTOP
[Desktop Entry]
Type=Application
Name=Ente Auth
Exec=$HOME/.local/bin/ente-auth.AppImage
Icon=ente-auth
Categories=Utility;Security;
Terminal=false
EODESKTOP
            ;;
    esac
    rm -rf "$temp_dir"
    success "Ente Auth (${ENTE_TAG}) installed."
}

install_keepassxc() {
    { command_exists keepassxc || command_exists keepassxc-cli; } \
        && { log "KeePassXC is already installed."; return; }
    log "Installing KeePassXC..."
    case "$PACKAGER" in
        nala|apt|zypper|dnf|yum) pkg_install keepassxc ;;
        pacman)  ${AUR_HELPER} --noconfirm -S keepassxc ;;
        nix-env) ${SUDO_CMD} ${PACKAGER} -iA nixos.keepassxc ;;
        *)       pkg_install keepassxc ;;
    esac
    { command_exists keepassxc || command_exists keepassxc-cli; } \
        && success "KeePassXC installed." \
        || error "Failed to install KeePassXC."
}

install_urbackup() {
    if command_exists urbackupclientctl; then
        log "UrBackup client is already installed."
    fi
    if ! prompt_yn "Install & configure UrBackup backup client?" n; then
        return 2
    fi
    bash "$DOTFILES_DIR/scripts/setup-urbackup-client.sh" || return 1
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
    local install_terragrunt=n install_gum=n install_glab=n

    prompt_yn "Install Terragrunt?"      n && install_terragrunt=y
    prompt_yn "Install Gum?"             n && install_gum=y
    prompt_yn "Install glab (GitLab CLI)?" n && install_glab=y
    prompt_yn "Install ghorg?"           n && install_ghorg
    prompt_yn "Install difftastic?"      n && install_difftastic

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

# Configs managed by the stow packages — kept in one place so backup and
# rollback agree on exactly what is touched.
managed_configs() {
    printf '%s\n' \
        ".zshrc" ".p10k.zsh" ".config/starship.toml" \
        ".config/fastfetch/config.jsonc" ".config/bat/config" \
        ".bashrc" ".bash_logout" ".bash_profile" ".profile" \
        ".config/lazygit/config.yml" ".gitconfig" \
        ".claude/settings.json" ".claude/statusline-command.sh" ".claude/statusline.sh"
}

# Stow packages applied by setup_dotfiles — recorded in the backup manifest so
# rollback knows what to unstow.
stow_packages() {
    printf '%s\n' zsh bash shell starship bat localbin git tmux lazygit ghorg claude
}

backup_configs() {
    # Collect the REAL files first — symlinks already pointing into the repo are
    # skipped. If nothing needs backing up, create no directory and no manifest
    # at all (avoids empty, manifest-only backup folders).
    local config
    local -a to_backup=()
    while IFS= read -r config; do
        if [ -f "$HOME/$config" ] && [ ! -L "$HOME/$config" ]; then
            to_backup+=("$config")
        fi
    done < <(managed_configs)

    if [ "${#to_backup[@]}" -eq 0 ]; then
        log "No real config files to back up — nothing to do."
        return 0
    fi

    BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    log "Backing up ${#to_backup[@]} existing config file(s) to $BACKUP_DIR ..."
    mkdir -p "$BACKUP_DIR" || error "Could not create backup directory $BACKUP_DIR"

    {
        echo "# dotfiles backup manifest"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "dotfiles_dir=$DOTFILES_DIR"
        echo "[packages]"
        stow_packages
        echo "[files]"
        printf '%s\n' "${to_backup[@]}"
    } > "$BACKUP_DIR/manifest.txt"

    # Archive all files in one compressed tarball, stored $HOME-relative so
    # rollback can extract straight back with `tar -C "$HOME"`.
    tar -czf "$BACKUP_DIR/files.tar.gz" -C "$HOME" "${to_backup[@]}" \
        || error "Failed to create backup archive $BACKUP_DIR/files.tar.gz"

    # Only remove originals once the archive is safely written.
    for config in "${to_backup[@]}"; do
        rm -f "$HOME/$config"
    done

    success "Backed up ${#to_backup[@]} config file(s) to files.tar.gz. Roll back with: setup.sh --rollback"
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

rollback_mode() {
    [ -d "$BACKUP_ROOT" ] || error "No backups found at $BACKUP_ROOT"
    local backups=()
    local d
    while IFS= read -r d; do backups+=("$d"); done \
        < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
    [ "${#backups[@]}" -eq 0 ] && error "No backups found at $BACKUP_ROOT"

    local chosen="${backups[0]}"
    if [ -z "$DOTFILES_YES" ] && has_tty; then
        log "Available backups (newest first):" "$BOLD"
        local i
        for i in "${!backups[@]}"; do
            printf '  %2d) %s\n' "$((i + 1))" "$(basename "${backups[$i]}")"
        done
        local sel
        read -r -p "Select a backup to restore [1]: " sel < /dev/tty
        sel="${sel:-1}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#backups[@]}" ]; then
            chosen="${backups[$((sel - 1))]}"
        else
            error "Invalid selection: $sel"
        fi
    fi

    local manifest="$chosen/manifest.txt"
    [ -f "$manifest" ] || error "Backup is missing manifest.txt: $chosen"
    log "Rolling back from $(basename "$chosen") ..." "$BLUE"

    # Resolve the repo dir so we can unstow from it.
    DOTFILES_DIR="$(grep -m1 '^dotfiles_dir=' "$manifest" | cut -d= -f2-)"
    [ -d "$DOTFILES_DIR" ] || DOTFILES_DIR="$CLONE_DIR"

    # 1) Unstow the packages that were applied.
    if [ -d "$DOTFILES_DIR" ] && command_exists stow; then
        local pkg in_pkgs=0
        while IFS= read -r pkg; do
            case "$pkg" in
                "[packages]") in_pkgs=1; continue ;;
                "[files]")    break ;;
            esac
            [ "$in_pkgs" = 1 ] && [ -d "$DOTFILES_DIR/$pkg" ] \
                && (cd "$DOTFILES_DIR" && stow -D -v -t "$HOME" "$pkg" 2>/dev/null) \
                && log "  unstowed $pkg"
        done < "$manifest"
    fi

    # 2) Restore the saved files.
    local restored=0
    if [ -f "$chosen/files.tar.gz" ]; then
        # New-style backup: one compressed archive, files stored $HOME-relative.
        tar -xzf "$chosen/files.tar.gz" -C "$HOME" \
            || error "Failed to extract $chosen/files.tar.gz"
        restored=$(tar -tzf "$chosen/files.tar.gz" | grep -cv '/$')
        log "  restored $restored file(s) from files.tar.gz"
    else
        # Legacy backup: loose files copied alongside the manifest.
        local f in_files=0
        while IFS= read -r f; do
            case "$f" in
                "[files]") in_files=1; continue ;;
            esac
            [ "$in_files" = 1 ] || continue
            [[ "$f" == \#* || -z "$f" ]] && continue
            if [ -f "$chosen/$f" ]; then
                mkdir -p "$(dirname "$HOME/$f")"
                cp -a "$chosen/$f" "$HOME/$f"
                restored=$((restored + 1))
                log "  restored $f"
            fi
        done < "$manifest"
    fi

    success "Rollback complete: restored $restored file(s) from $(basename "$chosen")."
}

# True when every file in package $1 is already symlinked from $HOME back into
# this repo (resolved by real path, so a correct link counts even if its text
# differs). Lets us skip stow entirely when the package is already in place —
# avoids needless restow churn and the spurious GNU Stow "find_stowed_path"
# warning it can trigger while rescanning the target tree. Must be called with
# the cwd set to $DOTFILES_DIR.
pkg_already_stowed() {
    local pkg="$1" src rel dest
    while IFS= read -r src; do
        rel="${src#"$pkg/"}"
        dest="$HOME/$rel"
        [ -L "$dest" ] || return 1
        [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ] || return 1
    done < <(find "$pkg" \( -type f -o -type l \))
    return 0
}

# Remove ONLY stale or dangling symlinks at a package's managed paths so a fresh
# stow can take over (e.g. a leftover link into an old/differently-named stow
# dir, which stow would otherwise refuse as "not owned by stow"). Real files are
# never touched — those are handled by backup_configs. Must run with cwd set to
# $DOTFILES_DIR.
clear_stale_links() {
    local pkg="$1" src rel dest
    while IFS= read -r src; do
        rel="${src#"$pkg/"}"
        dest="$HOME/$rel"
        if [ -L "$dest" ] && [ "$(readlink -f "$dest")" != "$(readlink -f "$src")" ]; then
            log "  removing stale symlink: $dest -> $(readlink "$dest")"
            rm -f "$dest"
        fi
    done < <(find "$pkg" \( -type f -o -type l \))
}

setup_dotfiles() {
    log "Setting up dotfiles via stow..."
    [ -d "$DOTFILES_DIR" ] || error "Dotfiles directory not found: $DOTFILES_DIR"
    cd "$DOTFILES_DIR" || error "Could not enter $DOTFILES_DIR"
    mkdir -p localbin

    local pkg
    while IFS= read -r pkg; do
        if [ -d "$pkg" ]; then
            if pkg_already_stowed "$pkg"; then
                log "$pkg already stowed correctly — skipping."
                continue
            fi
            clear_stale_links "$pkg"
            log "Stowing $pkg..."
            stow --no-folding -v -R -t "$HOME" "$pkg" || error "Failed to stow $pkg"
        else
            log "Warning: package directory '$pkg' not found, skipping."
        fi
    done < <(stow_packages)

    # Put repo-sync on PATH
    if [ -f "$DOTFILES_DIR/scripts/repo-sync" ]; then
        mkdir -p "$HOME/.local/bin"
        chmod +x "$DOTFILES_DIR/scripts/repo-sync"
        ln -sf "$DOTFILES_DIR/scripts/repo-sync" "$HOME/.local/bin/repo-sync"
        log "repo-sync linked to ~/.local/bin/repo-sync"
    fi

    if [ -f "$DOTFILES_DIR/scripts/setup-urbackup-client.sh" ]; then
        mkdir -p "$HOME/.local/bin"
        chmod +x "$DOTFILES_DIR/scripts/setup-urbackup-client.sh"
        ln -sf "$DOTFILES_DIR/scripts/setup-urbackup-client.sh" "$HOME/.local/bin/setup-urbackup-client"
        log "setup-urbackup-client linked to ~/.local/bin/setup-urbackup-client"
    fi
}

# Maintain ~/.shell/.exports.local — the gitignored file holding real secret
# values, sourced after the tracked (secret-free) .exports. We only ADD keys
# declared in the committed template that aren't already present; existing keys
# and their values are never modified or removed. Run after setup_dotfiles so
# the stowed ~/.shell/ directory exists.
merge_local_exports() {
    local tmpl="$DOTFILES_DIR/shell/.shell/.exports.local.template"
    local target="$HOME/.shell/.exports.local"
    [ -f "$tmpl" ] || { log "No .exports.local.template — skipping secrets setup."; return 0; }

    mkdir -p "$HOME/.shell"
    if [ ! -f "$target" ]; then
        cp "$tmpl" "$target"
        chmod 600 "$target"
        success "Created $target from template — edit it to fill in your secret values."
        return 0
    fi

    chmod 600 "$target" 2>/dev/null || true
    local line key added=0
    while IFS= read -r line; do
        case "$line" in
            export\ *=*)
                key="${line#export }"; key="${key%%=*}"
                if ! grep -qE "^[[:space:]]*export[[:space:]]+${key}=" "$target"; then
                    printf '%s\n' "$line" >> "$target"
                    log "  added new secret key: $key"
                    added=$((added + 1))
                fi ;;
        esac
    done < "$tmpl"
    if [ "$added" -gt 0 ]; then
        success "Added $added new key(s) to $target (existing values left untouched)."
    else
        log ".exports.local already has every template key — nothing to add."
    fi
}

configure_shell_preference() {
    if prompt_yn "Use zsh as your default shell?" y && [ "$SHELL" != "$(command -v zsh)" ]; then
        chsh -s "$(command -v zsh)"
        success "Log out and back in to use zsh. Then run 'p10k configure' to set up the theme."
    else
        success "Keeping current shell."
    fi
}

# ---------------------------------------------------------------------------
# CLI / interactivity plumbing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
dotfiles setup

Usage:
  curl -fsSL ${REPO_URL%.git}/raw/master/setup.sh | bash
  ./setup.sh [options]

Options:
  -y, --yes        Assume "yes" to every optional prompt (non-interactive install).
      --minimal    Base dependencies + dotfiles only; skip optional/heavy tools.
      --rollback   Restore configs from a previous backup and unstow packages.
      --no-clone   Use the current directory as the repo (skip clone/re-exec).
  -h, --help       Show this help and exit.

Environment:
  DOTFILES_DIR=<path>   Repo location to clone to / use (default: ~/.dotfiles).
  DOTFILES_YES=1        Same as --yes.
  DOTFILES_MINIMAL=1    Same as --minimal.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)    DOTFILES_YES=1 ;;
            --minimal)   DOTFILES_MINIMAL=1 ;;
            --rollback)  DO_ROLLBACK=1 ;;
            --no-clone)  NO_CLONE=1 ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage; error "Unknown option: $1" ;;
        esac
        shift
    done
}

# Ask a yes/no question. Honors --yes / --minimal / no-TTY defaults.
# Usage: prompt_yn "Question?" [default y|n]   -> returns 0 (yes) / 1 (no)
prompt_yn() {
    local question="$1" default="${2:-n}"
    [ -n "$DOTFILES_YES" ] && return 0
    # In minimal mode, optional tools default to "no" unless the default is yes.
    if [ -n "$DOTFILES_MINIMAL" ]; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    if has_tty; then
        local hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
        local ans
        read -r -p "$(echo -e "${YELLOW}${question} ${hint} ${RC}")" ans < /dev/tty
        ans="${ans:-$default}"
        [[ "$ans" =~ ^[Yy]$ ]]
    else
        log "  (no TTY) defaulting '$question' to '$default'"
        [ "$default" = "y" ]
    fi
}

# Run a named install phase as a numbered, non-fatal step.
# Usage: run_step "Label" function_name [args...]
run_step() {
    local label="$1"; shift
    STEP=$((STEP + 1))
    log "[ $STEP/$TOTAL ] $label" "$BLUE"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        STEPS_OK+=("$label")
    elif [ "$rc" -eq 2 ]; then
        STEPS_SKIPPED+=("$label")
    else
        log "  ✗ $label failed — continuing" "$RED"
        STEPS_FAILED+=("$label")
    fi
}

print_summary() {
    echo
    log "──────────────────────────────────────────" "$BOLD"
    log " Setup summary" "$BOLD"
    log "──────────────────────────────────────────" "$BOLD"
    success "  ✓ ${#STEPS_OK[@]} step(s) completed"
    if [ "${#STEPS_SKIPPED[@]}" -gt 0 ]; then
        log "  • ${#STEPS_SKIPPED[@]} step(s) skipped:"
        local sk
        for sk in "${STEPS_SKIPPED[@]}"; do log "      - $sk"; done
    fi
    if [ "${#STEPS_FAILED[@]}" -gt 0 ]; then
        log "  ✗ ${#STEPS_FAILED[@]} step(s) failed:" "$RED"
        local s
        for s in "${STEPS_FAILED[@]}"; do log "      - $s" "$RED"; done
    fi
    echo
    [ -n "$BACKUP_DIR" ] && log "  Backup:   $BACKUP_DIR"
    log "  Rollback: setup.sh --rollback"
    echo
    success "Setup complete! Restart your shell to see the changes."
    log "  Next: 'p10k configure', 'gh auth login'; re-login for docker/zsh changes."
}

# ---------------------------------------------------------------------------
# Bootstrap (curl|bash → clone repo to disk and re-exec)
# ---------------------------------------------------------------------------

# True when $0 is a real file sitting next to the stow packages (a genuine clone).
running_from_clone() {
    local self="${BASH_SOURCE[0]}"
    [ -f "$self" ] || return 1
    local dir
    dir="$(cd "$(dirname "$self")" && pwd)" || return 1
    [ -d "$dir/.git" ] && [ -d "$dir/zsh" ] && [ -d "$dir/shell" ]
}

bootstrap_repo() {
    # Prefer the script's own directory when it's a real file on disk.
    if [ -n "$NO_CLONE" ] || running_from_clone; then
        if [ -f "${BASH_SOURCE[0]}" ]; then
            DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        else
            DOTFILES_DIR="${DOTFILES_DIR:-$(pwd)}"
        fi
        return 0
    fi

    # curl|bash path: get the repo onto disk, then re-exec from there.
    log "Bootstrapping dotfiles repo into $CLONE_DIR ..." "$BLUE"
    ensure_git
    if [ -d "$CLONE_DIR/.git" ]; then
        log "Repo already present — updating..."
        git -C "$CLONE_DIR" pull --ff-only || log "  (pull failed; using existing checkout)"
    else
        git clone "$REPO_URL" "$CLONE_DIR" || error "Failed to clone $REPO_URL"
    fi
    DOTFILES_DIR="$CLONE_DIR"
    log "Re-executing from $CLONE_DIR/setup.sh ..." "$BLUE"
    exec bash "$CLONE_DIR/setup.sh" --no-clone "$@"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [ -n "$DO_ROLLBACK" ]; then
        rollback_mode
        exit 0
    fi

    # May re-exec and not return (curl|bash). After this, DOTFILES_DIR is set.
    bootstrap_repo "$@"

    TOTAL=23
    checkEnv

    run_step "Configuring package repositories" setup_repositories
    run_step "Installing base dependencies"      installDepend
    run_step "Configuring bat"                    setup_bat
    run_step "Installing fastfetch"               install_fastfetch
    run_step "Installing GitHub CLI"              install_gh
    run_step "Installing Docker"                  install_docker
    run_step "Installing Vault"                   install_vault
    run_step "Installing devbox"                  install_devbox
    run_step "Installing stern"                   install_stern
    run_step "Installing tfenv"                   install_tfenv
    run_step "Installing Nerd Fonts"             install_nerd_fonts
    run_step "Setting up zsh + Powerlevel10k"     setup_shell_environment
    run_step "Installing fzf/zoxide/starship"     install_additional_tools
    run_step "Installing lazygit"                 install_lazygit
    run_step "Installing Claude Code"             install_claude
    run_step "Installing ghq"                     install_ghq
    run_step "Installing Syncthing"               install_syncthing
    run_step "Setting up Syncthing (pair with server)" setup_syncthing_laptop
    run_step "Installing Ente Auth"               install_ente_auth
    run_step "Installing KeePassXC"               install_keepassxc
    run_step "Installing UrBackup client"         install_urbackup
    run_step "Installing Kubernetes tools"        install_kubernetes_tools
    run_step "Configuring direnv"                 setup_direnv
    run_step "Optional tools"                     install_optional_tools

    # Critical steps — fatal on failure.
    backup_configs
    setup_dotfiles
    merge_local_exports
    configure_shell_preference

    print_summary
}

main "$@"

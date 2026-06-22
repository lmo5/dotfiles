#!/bin/bash
# One-click UrBackup client installer & configurator.
#
# Self-contained, cross-distro, idempotent. Safe to run standalone:
#   bash scripts/setup-urbackup-client.sh
# or piped from the internet (will prompt for auth key if TTY available).
#
# All tunables are env-overridable — see defaults below.

set -uo pipefail

# ── Defaults (override via environment) ──────────────────────────────────────
URBACKUP_SERVER="${URBACKUP_SERVER:-backup.ayplace.xyz}"
URBACKUP_PORT="${URBACKUP_PORT:-55415}"
URBACKUP_COMPUTERNAME="${URBACKUP_COMPUTERNAME:-$(hostname)}"
URBACKUP_VERSION="${URBACKUP_VERSION:-2.5.31}"
URBACKUP_AUTHKEY="${URBACKUP_AUTHKEY:-}"
URBACKUP_SNAPSHOT="${URBACKUP_SNAPSHOT:-auto}"

# ── Helpers ──────────────────────────────────────────────────────────────────
declare -r RC='\033[0m'
declare -r RED='\033[31m'
declare -r YELLOW='\033[33m'
declare -r GREEN='\033[32m'

log()     { echo -e "${2:-$YELLOW}$1${RC}"; }
error()   { log "$1" "$RED" >&2; exit 1; }
success() { log "$1" "$GREEN"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

has_tty() { (exec < /dev/tty) 2>/dev/null; }

# ── Auth-key resolution ──────────────────────────────────────────────────────
resolve_authkey() {
    # 1) Already set via env
    if [ -n "$URBACKUP_AUTHKEY" ]; then
        log "Using URBACKUP_AUTHKEY from environment."
        return 0
    fi

    # 2) Source from ~/.shell/.exports.local
    local exports_local="$HOME/.shell/.exports.local"
    if [ -f "$exports_local" ]; then
        # shellcheck source=/dev/null
        source "$exports_local"
        if [ -n "${URBACKUP_AUTHKEY:-}" ]; then
            log "Loaded URBACKUP_AUTHKEY from $exports_local."
            return 0
        fi
    fi

    # 3) Interactive prompt (TTY required)
    if has_tty; then
        log "No URBACKUP_AUTHKEY found. Enter the UrBackup internet auth key."
        read -rs -p "Auth key: " URBACKUP_AUTHKEY < /dev/tty
        echo  # newline after silent read
        [ -n "$URBACKUP_AUTHKEY" ] || error "Auth key cannot be empty."

        # Persist to exports.local
        mkdir -p "$(dirname "$exports_local")"
        if [ ! -f "$exports_local" ]; then
            touch "$exports_local"
            chmod 600 "$exports_local"
        fi
        printf '\nexport URBACKUP_AUTHKEY="%s"\n' "$URBACKUP_AUTHKEY" >> "$exports_local"
        chmod 600 "$exports_local"
        log "Saved URBACKUP_AUTHKEY to $exports_local (mode 600)."
        return 0
    fi

    error "No URBACKUP_AUTHKEY set and no TTY available for interactive prompt. Set URBACKUP_AUTHKEY in the environment or in ~/.shell/.exports.local."
}

# ── Install UrBackup client ──────────────────────────────────────────────────
install_client() {
    if command_exists urbackupclientctl; then
        log "urbackupclientctl already installed — skipping download."
        return 0
    fi

    log "Installing UrBackup client v${URBACKUP_VERSION}..."
    local url="https://hndl.urbackup.org/Client/${URBACKUP_VERSION}/UrBackup%20Client%20Linux%20${URBACKUP_VERSION}.sh"
    local tmp
    tmp="$(mktemp)"

    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        error "Failed to download UrBackup client installer from $url"
    fi

    # Run installer non-interactively (stdin closed)
    sudo sh "$tmp" </dev/null || { rm -f "$tmp"; error "UrBackup installer failed."; }
    rm -f "$tmp"

    command_exists urbackupclientctl || error "urbackupclientctl not found after install — something went wrong."
    success "UrBackup client installed."
}

# ── Snapshot auto-detect ─────────────────────────────────────────────────────
configure_snapshots() {
    if [ "$URBACKUP_SNAPSHOT" != "auto" ]; then
        log "Snapshot mode override: $URBACKUP_SNAPSHOT (skipping auto-detect)."
        return 0
    fi

    local root_fs
    root_fs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    log "Root filesystem type: ${root_fs:-unknown}"

    # Backend reads this exact path (see urbackupclientbackend); the marker file
    # disables snapshots and must be removed when enabling a real method.
    local snapshot_cfg="/usr/local/etc/urbackup/snapshot.cfg"
    local share_dir="/usr/local/share/urbackup"
    local nosnap_marker="/usr/local/etc/urbackup/no_filesystem_snapshot"

    if [ "$root_fs" = "btrfs" ] && [ -f "$share_dir/btrfs_create_filesystem_snapshot" ]; then
        log "Configuring btrfs snapshots..."
        sudo tee "$snapshot_cfg" >/dev/null <<EOF
create_filesystem_snapshot=$share_dir/btrfs_create_filesystem_snapshot
remove_filesystem_snapshot=$share_dir/btrfs_remove_filesystem_snapshot
EOF
        sudo rm -f "$nosnap_marker"
        success "Btrfs snapshot support configured."
    elif [ "$root_fs" = "ext4" ] || [ "$root_fs" = "xfs" ]; then
        # Check for LVM thin provisioning
        local root_dev
        root_dev="$(findmnt -no SOURCE / 2>/dev/null || true)"
        if [ -n "$root_dev" ] && command_exists lvs; then
            local pool
            pool="$(lvs --noheadings -o pool_lv "$root_dev" 2>/dev/null | tr -d ' ')" || true
            if [ -n "$pool" ] && [ -f "$share_dir/lvm_create_filesystem_snapshot" ]; then
                log "Configuring LVM thin-provisioned snapshots..."
                sudo tee "$snapshot_cfg" >/dev/null <<EOF
create_filesystem_snapshot=$share_dir/lvm_create_filesystem_snapshot
remove_filesystem_snapshot=$share_dir/lvm_remove_filesystem_snapshot
EOF
                sudo rm -f "$nosnap_marker"
                success "LVM thin snapshot support configured."
                return 0
            fi
        fi
        log "No btrfs or LVM thin provisioning detected — using default (no snapshots)."
    else
        log "Filesystem '$root_fs' does not support snapshots — using default (none)."
    fi
}

# ── Configure internet mode ──────────────────────────────────────────────────
configure_internet_mode() {
    log "Configuring UrBackup internet mode..."
    sudo urbackupclientctl set-settings -k internet_mode_enabled -v true
    sudo urbackupclientctl set-settings -k internet_server -v "$URBACKUP_SERVER"
    sudo urbackupclientctl set-settings -k internet_server_port -v "$URBACKUP_PORT"
    sudo urbackupclientctl set-settings -k internet_authkey -v "$URBACKUP_AUTHKEY"
    if [ -n "$URBACKUP_COMPUTERNAME" ]; then
        sudo urbackupclientctl set-settings -k computername -v "$URBACKUP_COMPUTERNAME"
    fi
    success "Internet mode configured: server=$URBACKUP_SERVER:$URBACKUP_PORT"
}

# ── Enable + restart service ─────────────────────────────────────────────────
restart_service() {
    log "Enabling and restarting urbackupclientbackend service..."
    sudo systemctl enable --now urbackupclientbackend
    sudo systemctl restart urbackupclientbackend
    success "Service urbackupclientbackend enabled and restarted."
}

# ── Verify connectivity ─────────────────────────────────────────────────────
verify_connection() {
    log "Waiting for UrBackup client to connect (up to 30s)..."
    log "  Note: the client may wait up to 3 minutes for a local server before"
    log "  trying internet mode on first start — this is normal."

    local i status
    for i in $(seq 1 6); do
        status="$(urbackupclientctl status 2>/dev/null || true)"
        if echo "$status" | grep -q '"internet_connected"' && echo "$status" | grep -qi 'true'; then
            success "Client reports internet_connected."
            echo "$status" | grep -E '"(internet_connected|servers)"' || true
            return 0
        fi
        [ "$i" -lt 6 ] && sleep 5
    done

    log "Client has not reported internet_connected yet (this may be normal on first start)."
    log "Current status:"
    urbackupclientctl status 2>/dev/null || log "  (could not retrieve status)"
    log "Check again in a few minutes: urbackupclientctl status"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log "UrBackup client setup" "\033[1m"
    log "Server: $URBACKUP_SERVER:$URBACKUP_PORT"

    resolve_authkey
    install_client
    configure_snapshots
    configure_internet_mode
    restart_service
    verify_connection

    success "UrBackup client setup complete."
}

main "$@"

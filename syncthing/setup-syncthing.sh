#!/usr/bin/env bash
# setup-syncthing.sh — Bootstrap Syncthing on a laptop and pair it with the hub server
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SYNCTHING_SERVER_URL="https://sync.ayplace.xyz"
SYNCTHING_LOCAL_URL="${STSYNC_URL:-http://127.0.0.1:8384}"
SHELL_ENV="$HOME/.shell/.env"

# ── Colors / helpers ──────────────────────────────────────────────────────────
RC='\033[0m'; RED='\033[31m'; YELLOW='\033[33m'; GREEN='\033[32m'
log()     { printf "${YELLOW}%s${RC}\n" "$1"; }
success() { printf "${GREEN}%s${RC}\n" "$1"; }
error()   { printf "${RED}%s${RC}\n" "$1" >&2; exit 1; }

# ── 1. Ensure Syncthing is installed ─────────────────────────────────────────
install_syncthing() {
    if command -v syncthing &>/dev/null; then
        log "Syncthing is already installed."
        return
    fi
    log "Installing Syncthing..."
    sudo mkdir -p /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/syncthing-archive-keyring.gpg ]; then
        curl -s https://syncthing.net/release-key.gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/syncthing-archive-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" \
            | sudo tee /etc/apt/sources.list.d/syncthing.list > /dev/null
        sudo apt-get update -qq
    fi
    sudo apt-get install -y syncthing
    success "Syncthing installed."
}

# ── 2. Enable the user service ────────────────────────────────────────────────
enable_service() {
    if systemctl --user is-active syncthing &>/dev/null; then
        log "Syncthing user service is already running."
        return
    fi
    log "Enabling Syncthing user service..."
    systemctl --user enable --now syncthing
    log "Waiting for Syncthing API to become available..."
    for i in $(seq 1 30); do
        if curl -sf -o /dev/null "$SYNCTHING_LOCAL_URL/rest/system/status" 2>/dev/null; then
            success "Syncthing is up."
            return
        fi
        sleep 1
    done
    error "Syncthing did not start within 30 seconds. Check 'systemctl --user status syncthing'."
}

# ── 3. Read local API key ────────────────────────────────────────────────────
get_api_key() {
    if [[ -n "${STSYNC_APIKEY:-}" ]]; then
        printf '%s' "$STSYNC_APIKEY"
        return
    fi
    local cfg="$HOME/.local/state/syncthing/config.xml"
    [[ -f "$cfg" ]] || error "Syncthing config not found at $cfg — is the service running?"
    sed -n 's|.*<apikey>\([^<]*\)</apikey>.*|\1|p' "$cfg"
}

# ── 4. Fetch the server's Device ID ──────────────────────────────────────────
fetch_server_device_id() {
    if [[ -n "${STSYNC_SERVER_DEVICE_ID:-}" ]]; then
        printf '%s' "$STSYNC_SERVER_DEVICE_ID"
        return
    fi
    log "Fetching server Device ID from $SYNCTHING_SERVER_URL ..."
    local status device_id
    if status=$(curl -sf --max-time 10 "$SYNCTHING_SERVER_URL/rest/system/status" 2>/dev/null); then
        device_id=$(printf '%s' "$status" | python3 -c "import sys,json; print(json.load(sys.stdin)['myID'])" 2>/dev/null) \
            || error "Failed to parse device ID from server response."
        [[ -n "$device_id" ]] || error "Server returned an empty device ID."
        printf '%s' "$device_id"
    else
        log "Cannot reach $SYNCTHING_SERVER_URL — falling back to manual input."
        printf 'Enter the server Device ID: ' >&2
        read -r device_id
        [[ -n "$device_id" ]] || error "No device ID provided."
        printf '%s' "$device_id"
    fi
}

# ── 5. Add server as remote device with Introducer enabled ───────────────────
add_server_device() {
    local api_key="$1" server_id="$2"

    local existing
    existing=$(curl -s -H "X-API-Key: $api_key" "$SYNCTHING_LOCAL_URL/rest/config/devices" \
        | python3 -c "import sys,json; ids=[d['deviceID'] for d in json.load(sys.stdin)]; print('$server_id' in ids)" 2>/dev/null)

    if [[ "$existing" == "True" ]]; then
        log "Server device is already configured — ensuring Introducer is enabled."
        local current
        current=$(curl -s -H "X-API-Key: $api_key" \
            "$SYNCTHING_LOCAL_URL/rest/config/devices/$server_id")
        local updated
        updated=$(printf '%s' "$current" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); d['introducer']=True; d['autoAcceptFolders']=True; print(json.dumps(d))")
        curl -s -o /dev/null -w '' \
            -X PUT \
            -H "X-API-Key: $api_key" \
            -H "Content-Type: application/json" \
            -d "$updated" \
            "$SYNCTHING_LOCAL_URL/rest/config/devices/$server_id"
        success "Server device updated (introducer=true, autoAcceptFolders=true)."
        return
    fi

    log "Adding server as remote device..."
    local payload
    payload=$(python3 -c "
import json
print(json.dumps({
    'deviceID': '$server_id',
    'name': 'sync-server',
    'addresses': ['dynamic'],
    'compression': 'metadata',
    'introducer': True,
    'autoAcceptFolders': True,
    'paused': False
}))
")

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST \
        -H "X-API-Key: $api_key" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SYNCTHING_LOCAL_URL/rest/config/devices")

    if [[ "$http_code" == "200" ]]; then
        success "Server device added (introducer=true, autoAcceptFolders=true)."
    else
        error "Failed to add server device (HTTP $http_code). Check the Syncthing web UI."
    fi
}

# ── 6. Persist STSYNC_SERVER_DEVICE_ID in shell env ──────────────────────────
persist_env() {
    local server_id="$1"

    if grep -q '^export STSYNC_SERVER_DEVICE_ID=' "$SHELL_ENV" 2>/dev/null; then
        sed -i "s|^export STSYNC_SERVER_DEVICE_ID=.*|export STSYNC_SERVER_DEVICE_ID=\"$server_id\"|" "$SHELL_ENV"
        log "Updated STSYNC_SERVER_DEVICE_ID in $SHELL_ENV"
    else
        printf '\nexport STSYNC_SERVER_DEVICE_ID="%s"\n' "$server_id" >> "$SHELL_ENV"
        log "Added STSYNC_SERVER_DEVICE_ID to $SHELL_ENV"
    fi
    export STSYNC_SERVER_DEVICE_ID="$server_id"
}

# ── 7. Remove the default ~/Sync folder ──────────────────────────────────────
remove_default_folder() {
    local api_key="$1"
    local exists
    exists=$(curl -s -H "X-API-Key: $api_key" "$SYNCTHING_LOCAL_URL/rest/config/folders" \
        | python3 -c "import sys,json; print(any(f['id']=='default' for f in json.load(sys.stdin)))" 2>/dev/null)

    if [[ "$exists" == "True" ]]; then
        log "Removing default ~/Sync folder from Syncthing config..."
        curl -s -o /dev/null \
            -X DELETE \
            -H "X-API-Key: $api_key" \
            "$SYNCTHING_LOCAL_URL/rest/config/folders/default"
        success "Default folder removed."
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "=== Syncthing Laptop Setup ==="
    echo

    install_syncthing
    enable_service

    local api_key server_id
    api_key="$(get_api_key)"
    server_id="$(fetch_server_device_id)"

    log "Server Device ID: $server_id"
    echo

    add_server_device "$api_key" "$server_id"
    persist_env "$server_id"
    remove_default_folder "$api_key"

    echo
    success "=== Setup complete ==="
    echo
    log "Next steps:"
    log "  1. Accept this laptop on the server: $SYNCTHING_SERVER_URL"
    log "  2. Register repos with:  repo-sync add ~/repos/<host>/<owner>/<repo>"
    log "  3. Web UI: $SYNCTHING_LOCAL_URL"
}

main "$@"

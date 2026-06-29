#!/usr/bin/env bash
# setup-ai-stack.sh — install/configure the personal AI CLI stack:
#   Layer 1  Claude Code (personal subscription)        — assumed already installed
#   Layer 2  gemini-cli delegation (company, free)      — ask-gemini wrapper + slash cmd + MCP
#   Layer 3  9router + pi + Headroom context compression — cheap/overflow + token saver
#
# Idempotent and opt-in: re-running is safe, every component is guarded.
# No secrets are written. The 9router endpoint key is left as a placeholder you must fill.
#
# Usage:  bash setup-ai-stack.sh
set -euo pipefail

log()  { printf '\033[1;34m[ai-stack]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ask()  { local p="$1" d="${2:-n}" a; read -r -p "$p [y/N] " a; [[ "${a:-$d}" =~ ^[Yy]$ ]]; }

need() { command -v "$1" >/dev/null 2>&1; }

BIN_DIR="$HOME/bin"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$BIN_DIR" "$CLAUDE_DIR/commands"

# ---------------------------------------------------------------------------
# Layer 2 — Gemini delegation
# ---------------------------------------------------------------------------
setup_gemini_delegation() {
    if ! need npm; then warn "npm not found — skipping Gemini/9router/pi (install Node first)"; return 1; fi

    if ! need gemini && ! ls "$HOME"/.config/nvm/versions/node/*/bin/gemini >/dev/null 2>&1; then
        if ask "Install @google/gemini-cli globally?"; then
            npm install -g @google/gemini-cli && ok "gemini-cli installed"
        else
            warn "gemini-cli missing — ask-gemini wrapper will not work until installed"
        fi
    else
        ok "gemini-cli present"
    fi

    # ask-gemini wrapper
    cat > "$BIN_DIR/ask-gemini" <<'EOF'
#!/usr/bin/env bash
# Delegate a prompt to the company enterprise Gemini CLI (free, ~1M context).
# Prints only the model's answer. Use @path refs to feed files into Gemini's
# big context instead of spending Claude tokens:  ask-gemini "@src/ summarize"
set -euo pipefail
[[ $# -eq 0 ]] && { echo "usage: ask-gemini <prompt>  (supports @file / @dir)" >&2; exit 2; }
# Prefer gemini on PATH; fall back to a node-global install if PATH lacks it.
GEMINI_BIN="${GEMINI_BIN:-}"
if [[ -z "$GEMINI_BIN" ]]; then
  if command -v gemini >/dev/null 2>&1; then GEMINI_BIN=gemini
  else GEMINI_BIN=$(ls "$HOME"/.config/nvm/versions/node/*/bin/gemini 2>/dev/null | tail -1); fi
fi
"$GEMINI_BIN" -p "$*" -o json 2>/dev/null | jq -r '.response'
EOF
    chmod +x "$BIN_DIR/ask-gemini"
    ok "wrote $BIN_DIR/ask-gemini"

    # /ask-gemini slash command
    cat > "$CLAUDE_DIR/commands/ask-gemini.md" <<'EOF'
---
description: Delegate a prompt to free company Gemini (1M context) and use its answer
argument-hint: <prompt, supports @file / @dir refs>
allowed-tools: Bash(~/bin/ask-gemini:*)
---
Gemini (company enterprise, free, huge context) was asked: "$ARGUMENTS"

Its response:

!`~/bin/ask-gemini "$ARGUMENTS"`

Use this response to continue. Prefer delegating large-context reads, log/diff
summarization, and bulk analysis to Gemini instead of spending Claude tokens.
EOF
    ok "wrote $CLAUDE_DIR/commands/ask-gemini.md"

    # gemini-cli MCP server (forces enterprise binary, not retired agy)
    if need claude && ask "Register gemini-cli MCP server in Claude Code?"; then
        claude mcp add gemini-cli -s user --env GEMINI_MCP_BACKEND=gemini -- npx -y gemini-mcp-tool \
            && ok "MCP gemini-cli registered" || warn "MCP add failed (maybe already exists)"
    fi
}

# ---------------------------------------------------------------------------
# Layer 3 — 9router
# ---------------------------------------------------------------------------
setup_9router() {
    if ! need 9router; then
        if ask "Install 9router globally?"; then npm install -g 9router && ok "9router installed"; fi
    else ok "9router present"; fi

    # claude-9r launcher (placeholder key — fill from the 9router dashboard)
    if [[ ! -f "$BIN_DIR/claude-9r" ]]; then
        cat > "$BIN_DIR/claude-9r" <<'EOF'
#!/usr/bin/env bash
# Claude Code routed through the local 9router proxy (Layer 3 overflow).
# Isolated CLAUDE_CONFIG_DIR so it never touches your native subscription login.
# First run in this profile: /logout to drop any inherited Anthropic session.
#
# SETUP: run `9router` -> dashboard http://localhost:20128 -> generate an
# Endpoint key, then replace 9r_REPLACE_ME below.
export CLAUDE_CONFIG_DIR="$HOME/.claude-9router"
export ANTHROPIC_BASE_URL="http://localhost:20128/v1"
export ANTHROPIC_AUTH_TOKEN="9r_REPLACE_ME"
export ANTHROPIC_API_KEY="9r_REPLACE_ME"
exec claude "$@"
EOF
        chmod +x "$BIN_DIR/claude-9r"
        ok "wrote $BIN_DIR/claude-9r (edit it to add your 9r endpoint key)"
    else
        ok "claude-9r already exists (left untouched — keeps your key)"
    fi
}

# ---------------------------------------------------------------------------
# Layer 3 — pi
# ---------------------------------------------------------------------------
setup_pi() {
    if ! need pi; then
        if ask "Install pi (@earendil-works/pi-coding-agent)?"; then
            npm install -g --ignore-scripts @earendil-works/pi-coding-agent && ok "pi installed"
        fi
    else ok "pi present"; fi
}

# ---------------------------------------------------------------------------
# Headroom context compression (9router -> :8787)
# ---------------------------------------------------------------------------
setup_headroom() {
    if ! need docker; then warn "docker not found — skipping Headroom"; return 0; fi
    ask "Set up Headroom context compression (docker, port 8787)?" || return 0

    if docker ps -a --format '{{.Names}}' | grep -qx headroom; then
        docker start headroom >/dev/null 2>&1 || true
        ok "headroom container already exists — started"
    else
        log "pulling ghcr.io/chopratejas/headroom:latest"
        docker pull ghcr.io/chopratejas/headroom:latest
        docker run -d --name headroom --restart unless-stopped -p 8787:8787 \
            ghcr.io/chopratejas/headroom:latest
        ok "headroom proxy running on :8787"
    fi

    # Flip the 9router toggle via its own API client (handles auth token).
    local nr
    nr=$(ls -d "$HOME"/.config/nvm/versions/node/*/lib/node_modules/9router 2>/dev/null | tail -1)
    if [[ -n "$nr" && -f "$nr/src/cli/api/client.js" ]] && need node; then
        if node -e '
          const api = require(process.argv[1] + "/src/cli/api/client.js");
          api.updateSettings({ headroomEnabled: true })
            .then(r => { console.log(r && r.success ? "headroom enabled in 9router" : "toggle failed"); })
            .catch(e => { console.error(e.message); process.exit(1); });
        ' "$nr" 2>/dev/null; then
            ok "9router headroomEnabled=true"
        else
            warn "could not auto-toggle — enable in dashboard: Settings → Token Saver (Headroom)"
        fi
    else
        warn "9router not found to toggle — enable Headroom in its dashboard Settings"
    fi
}

main() {
    log "Personal AI CLI stack setup (Claude + Gemini + 9router + pi + Headroom)"
    setup_gemini_delegation || true
    if ask "Set up Layer 3 (9router overflow + pi + Headroom)?"; then
        setup_9router
        setup_pi
        setup_headroom
    fi
    echo
    ok "Done. Notes:"
    echo "  - Ensure ~/bin is on PATH:  export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\""
    echo "  - Fill the endpoint key in ~/bin/claude-9r from the 9router dashboard."
    echo "  - Start 9router with: 9router   (dashboard http://localhost:20128)"
    echo "  - Verify Gemini:  ~/bin/ask-gemini \"say hi\""
    echo "  - Verify Headroom:  curl http://localhost:8787/health"
}

main "$@"

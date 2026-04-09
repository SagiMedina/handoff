#!/usr/bin/env bash
# handoff-common.sh — Shared utilities for Handoff

HANDOFF_DIR="$HOME/.handoff"
HANDOFF_KEY="$HANDOFF_DIR/phone_key"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf "${BLUE}%s${RESET}\n" "$*"; }
success() { printf "${GREEN}%s${RESET}\n" "$*"; }
warn()    { printf "${YELLOW}%s${RESET}\n" "$*"; }
error()   { printf "${RED}%s${RESET}\n" "$*" >&2; }

require_cmd() {
    command -v "$1" &>/dev/null
}

# Check if Tailscale is running and connected
tailscale_is_up() {
    tailscale status &>/dev/null
}

# Start the Tailscale daemon (handles both brew and Mac App Store installs)
tailscale_start_daemon() {
    if [[ -d "/Applications/Tailscale.app" ]]; then
        open -a Tailscale
    else
        brew services start tailscale 2>/dev/null || sudo brew services start tailscale 2>/dev/null || true
    fi
}

# Ensure Tailscale is up — start it if not, wait for it, or fail with a clear message
ensure_tailscale() {
    if tailscale_is_up; then
        return 0
    fi

    if ! require_cmd tailscale; then
        error "  Tailscale is not installed."
        echo "    brew install tailscale"
        echo "    — or install from the Mac App Store"
        return 1
    fi

    info "  Starting Tailscale..."
    tailscale_start_daemon

    # Wait for the daemon to be reachable
    local i
    for i in $(seq 1 10); do
        if tailscale status &>/dev/null 2>&1 || tailscale up &>/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if tailscale_is_up; then
        success "  Tailscale connected."
        return 0
    fi

    # Daemon is up but not logged in — run tailscale up interactively
    if tailscale status 2>&1 | grep -qi "stopped\|needslogin\|not logged in"; then
        warn "  Tailscale needs login."
        tailscale up
        if tailscale_is_up; then
            success "  Tailscale connected."
            return 0
        fi
    fi

    error "  Could not start Tailscale."
    echo "    Try: open /Applications/Tailscale.app"
    echo "    — or: brew services start tailscale && tailscale up"
    return 1
}

# Get the Tailscale IPv4 address of this machine
tailscale_ip() {
    tailscale ip -4 2>/dev/null
}

# Check if macOS Remote Login (SSH) is enabled
ssh_is_enabled() {
    sudo systemsetup -getremotelogin 2>/dev/null | grep -qi "on"
}

# List tmux sessions as "name:window_count" lines
tmux_sessions() {
    tmux list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null
}

# Pretty-print tmux sessions
print_sessions() {
    local sessions
    sessions=$(tmux_sessions)
    if [[ -z "$sessions" ]]; then
        warn "  No active tmux sessions."
        return 1
    fi
    while IFS=: read -r name windows; do
        local label="window"
        [[ "$windows" -gt 1 ]] && label="windows"
        printf "  ${BOLD}*${RESET} %-16s ${DIM}(%s %s)${RESET}\n" "$name" "$windows" "$label"
    done <<< "$sessions"
}

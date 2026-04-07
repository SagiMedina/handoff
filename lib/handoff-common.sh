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

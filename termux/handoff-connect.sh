#!/usr/bin/env bash
# Handoff — Connect to Mac tmux session (standalone version)
# This is the same script that setup.sh installs to ~/.shortcuts/handoff
# Kept here for reference and manual installation.
set -euo pipefail

CONFIG_FILE="$HOME/.handoff/config"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Handoff not set up. Run the setup script first."
    exit 1
fi

source "$CONFIG_FILE"
SSH_HOST="handoff-mac"

echo ""
echo "  Connecting to Mac..."
echo ""

# Get tmux sessions from Mac
SESSIONS=$(ssh "$SSH_HOST" "$TMUX_PATH list-sessions -F '#{session_name}:#{session_windows}'" 2>/dev/null) || true

if [[ -z "$SESSIONS" ]]; then
    echo "  No active tmux sessions on Mac."
    read -rp "  Press Enter to exit..."
    exit 0
fi

SESSION_COUNT=$(echo "$SESSIONS" | wc -l | tr -d ' ')

# Pick session
if [[ "$SESSION_COUNT" -eq 1 ]]; then
    SESSION_NAME=$(echo "$SESSIONS" | cut -d: -f1)
else
    echo "  Sessions:"
    echo ""
    i=1
    declare -a SESSION_NAMES
    while IFS=: read -r name windows; do
        label="window"
        [[ "$windows" -gt 1 ]] && label="windows"
        printf "  %d) %-16s (%s %s)\n" "$i" "$name" "$windows" "$label"
        SESSION_NAMES+=("$name")
        ((i++))
    done <<< "$SESSIONS"
    echo ""
    read -rp "  Pick a session [1-$SESSION_COUNT]: " choice
    if [[ "$choice" -ge 1 && "$choice" -le "$SESSION_COUNT" ]] 2>/dev/null; then
        SESSION_NAME="${SESSION_NAMES[$((choice-1))]}"
    else
        echo "  Invalid choice."
        exit 1
    fi
fi

# Get windows for selected session
WINDOWS=$(ssh "$SSH_HOST" "$TMUX_PATH list-windows -t '$SESSION_NAME' -F '#{window_index}|#{pane_title}|#{pane_current_command}'" 2>/dev/null) || true
WINDOW_COUNT=$(echo "$WINDOWS" | wc -l | tr -d ' ')

if [[ "$WINDOW_COUNT" -le 1 ]]; then
    echo "  Attaching to: $SESSION_NAME"
    echo ""
    exec ssh -t "$SSH_HOST" "$TMUX_PATH attach -t '$SESSION_NAME'"
fi

# Multiple windows — show picker
echo ""
echo "  Windows in $SESSION_NAME:"
echo ""
i=1
declare -a WINDOW_INDICES
while IFS='|' read -r idx title cmd; do
    display="${title:-$cmd}"
    printf "  %d) %s\n" "$i" "$display"
    WINDOW_INDICES+=("$idx")
    ((i++))
done <<< "$WINDOWS"

echo ""
read -rp "  Pick a window [1-$WINDOW_COUNT]: " wchoice

if [[ "$wchoice" -ge 1 && "$wchoice" -le "$WINDOW_COUNT" ]] 2>/dev/null; then
    WIN_IDX="${WINDOW_INDICES[$((wchoice-1))]}"
    echo ""
    exec ssh -t "$SSH_HOST" "$TMUX_PATH attach -t '${SESSION_NAME}:${WIN_IDX}'"
else
    echo "  Invalid choice."
    exit 1
fi

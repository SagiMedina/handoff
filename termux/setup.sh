#!/usr/bin/env bash
# Handoff — Termux setup script
# Run on phone after scanning QR code from 'handoff pair'
# Usage: bash setup.sh <tailscale_ip> <user> <base64_private_key> <tmux_path>
set -euo pipefail

TAILSCALE_IP="${1:?Missing Tailscale IP}"
REMOTE_USER="${2:?Missing username}"
KEY_B64="${3:?Missing SSH key}"
TMUX_PATH="${4:-/opt/homebrew/bin/tmux}"

SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/handoff_key"
SHORTCUTS_DIR="$HOME/.shortcuts"
CONNECT_SCRIPT="$SHORTCUTS_DIR/handoff"
CONFIG_DIR="$HOME/.handoff"
CONFIG_FILE="$CONFIG_DIR/config"

echo ""
echo "  Handoff — Phone Setup"
echo "  ─────────────────────"
echo ""

# 1. Install openssh if needed
if ! command -v ssh &>/dev/null; then
    echo "  Installing openssh..."
    pkg install -y openssh
fi
echo "  ✓ openssh ready"

# 2. Save SSH private key
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
echo "$KEY_B64" | base64 -d > "$KEY_FILE"
chmod 600 "$KEY_FILE"
echo "  ✓ SSH key saved"

# 3. Add SSH config entry
if ! grep -q "Host handoff-mac" "$SSH_DIR/config" 2>/dev/null; then
    cat >> "$SSH_DIR/config" <<EOF

# Handoff — Mac connection
Host handoff-mac
    HostName $TAILSCALE_IP
    User $REMOTE_USER
    IdentityFile $KEY_FILE
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
    chmod 600 "$SSH_DIR/config"
    echo "  ✓ SSH config added"
else
    # Update existing entry with new IP
    sed -i "s/HostName .*/HostName $TAILSCALE_IP/" "$SSH_DIR/config"
    echo "  ✓ SSH config updated"
fi

# 4. Save connection config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
TAILSCALE_IP=$TAILSCALE_IP
REMOTE_USER=$REMOTE_USER
TMUX_PATH=$TMUX_PATH
EOF
echo "  ✓ Config saved"

# 5. Install connect script as Termux:Widget shortcut
mkdir -p "$SHORTCUTS_DIR"
cat > "$CONNECT_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# Handoff — Connect to Mac tmux session
set -euo pipefail

CONFIG_FILE="$HOME/.handoff/config"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Handoff not set up. Run setup first."
    read -rp "Press Enter to exit..."
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

if [[ "$SESSION_COUNT" -eq 1 ]]; then
    # Single session — connect directly
    SESSION_NAME=$(echo "$SESSIONS" | cut -d: -f1)
    echo "  Attaching to: $SESSION_NAME"
    echo ""
    exec ssh -t "$SSH_HOST" "$TMUX_PATH attach -t '$SESSION_NAME'"
fi

# Multiple sessions — show picker
echo "  Active sessions:"
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
    echo ""
    echo "  Attaching to: $SESSION_NAME"
    echo ""
    exec ssh -t "$SSH_HOST" "$TMUX_PATH attach -t '$SESSION_NAME'"
else
    echo "  Invalid choice."
    read -rp "  Press Enter to exit..."
    exit 1
fi
SCRIPT
chmod +x "$CONNECT_SCRIPT"
echo "  ✓ Shortcut installed"

echo ""
echo "  ✅ Setup complete!"
echo ""
echo "  To connect now, run:  handoff"
echo "  Or add the Termux:Widget to your home screen"
echo "  (long-press home → Widgets → Termux:Widget)"
echo ""

# Create a convenience alias
if ! grep -q "alias handoff=" "$HOME/.bashrc" 2>/dev/null; then
    echo "alias handoff='$CONNECT_SCRIPT'" >> "$HOME/.bashrc"
    echo "  Added 'handoff' alias to .bashrc"
fi

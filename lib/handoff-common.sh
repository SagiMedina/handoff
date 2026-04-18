#!/usr/bin/env bash
# handoff-common.sh — Shared utilities for Handoff

HANDOFF_DIR="$HOME/.handoff"
HANDOFF_KEY="$HANDOFF_DIR/phone_key"           # v1 legacy
HANDOFF_KEYS_DIR="$HANDOFF_DIR/keys"           # v2 per-device keys
HANDOFF_DEVICES="$HANDOFF_DIR/devices.json"    # v2 device registry
HANDOFF_ACCESS_LOG="$HANDOFF_DIR/access.log"   # gate access log

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

# Pretty-print tmux sessions with window details
print_sessions() {
    local sessions
    sessions=$(tmux_sessions)
    if [[ -z "$sessions" ]]; then
        warn "  No active tmux sessions."
        return 1
    fi
    while IFS=: read -r name windows; do
        local label="tab"
        [[ "$windows" -gt 1 ]] && label="tabs"
        printf "  ${BOLD}*${RESET} %-16s ${DIM}(%s %s)${RESET}\n" "$name" "$windows" "$label"
        # List individual windows with cwd
        local win_info
        win_info=$(tmux list-windows -t "$name" -F '#{pane_current_command}|#{pane_current_path}' 2>/dev/null)
        if [[ -n "$win_info" ]]; then
            while IFS='|' read -r cmd path; do
                local folder="${path%/}"
                folder="${folder##*/}"
                printf "    ${DIM}›${RESET} %-14s ${DIM}%s${RESET}\n" "$cmd" "$folder"
            done <<< "$win_info"
        fi
    done <<< "$sessions"
}

# ─── Device Registry (v2) ─────────────────────────────────────────

# Initialize devices.json if it doesn't exist
devices_json_init() {
    mkdir -p "$HANDOFF_KEYS_DIR"
    if [[ ! -f "$HANDOFF_DEVICES" ]]; then
        echo '{"version":1,"devices":[]}' > "$HANDOFF_DEVICES"
    fi
    touch "$HANDOFF_ACCESS_LOG"
}

# Add a device to devices.json
# Usage: devices_json_add_device name fingerprint key_file sessions read_only nonce soft_expiry hard_expiry
devices_json_add_device() {
    local name="$1" fingerprint="$2" key_file="$3" sessions="$4" \
          read_only="$5" nonce="$6" soft_expiry="$7" hard_expiry="$8"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local ro_py="False"
    [[ "$read_only" == "true" ]] && ro_py="True"
    python3 -c "
import json, sys
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
device = {
    'name': '$name',
    'fingerprint': '$fingerprint',
    'key_file': '$key_file',
    'status': 'pending',
    'sessions': $sessions,
    'read_only': $ro_py,
    'nonce': '$nonce',
    'created_at': '$now',
    'soft_expiry': '$soft_expiry',
    'hard_expiry': '$hard_expiry',
    'renewal_requested': False,
    'last_seen': None,
    'last_command': None
}
data['devices'].append(device)
with open('$HANDOFF_DEVICES', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# Update a field on a device by fingerprint
# Usage: devices_json_update_device fingerprint field value
devices_json_update_device() {
    local fingerprint="$1" field="$2" value="$3"
    python3 -c "
import json
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
for d in data['devices']:
    if d['fingerprint'] == '$fingerprint':
        val = '$value'
        if val == 'true': val = True
        elif val == 'false': val = False
        elif val == 'null': val = None
        d['$field'] = val
        break
with open('$HANDOFF_DEVICES', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# Get a device field by fingerprint
# Usage: devices_json_get_field fingerprint field
devices_json_get_field() {
    local fingerprint="$1" field="$2"
    python3 -c "
import json
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
for d in data['devices']:
    if d['fingerprint'] == '$fingerprint':
        v = d.get('$field')
        if v is None: print('')
        elif isinstance(v, bool): print(str(v).lower())
        elif isinstance(v, list): print(';'.join(v))
        else: print(v)
        break
"
}

# Get full device JSON by fingerprint
devices_json_get_device() {
    local fingerprint="$1"
    python3 -c "
import json
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
for d in data['devices']:
    if d['fingerprint'] == '$fingerprint':
        print(json.dumps(d))
        break
"
}

# Remove a device by fingerprint
devices_json_remove_device() {
    local fingerprint="$1"
    python3 -c "
import json
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
data['devices'] = [d for d in data['devices'] if d['fingerprint'] != '$fingerprint']
with open('$HANDOFF_DEVICES', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# Render an ISO-8601-ish timestamp as a short relative duration.
# "never" or empty → "never"; past → "expired"; future → "3d 4h" / "12h" / "45m".
format_relative_time() {
    local ts="${1:-}"
    if [[ -z "$ts" || "$ts" == "never" ]]; then
        echo "never"
        return
    fi
    python3 -c "
import sys
from datetime import datetime, timezone
raw = '$ts'
try:
    t = datetime.fromisoformat(raw.replace('Z', '+00:00'))
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
except Exception:
    print(raw[:19])
    sys.exit(0)
now = datetime.now(timezone.utc)
delta = t - now
secs = int(delta.total_seconds())
if secs <= 0:
    print('expired')
    sys.exit(0)
days, rem = divmod(secs, 86400)
hours, rem = divmod(rem, 3600)
mins = rem // 60
if days > 0: print(f'{days}d {hours}h')
elif hours > 0: print(f'{hours}h {mins}m')
else: print(f'{mins}m')
"
}

# List all devices as "fingerprint|name|status|sessions|mode|expiry|last_seen|renewal_requested"
devices_json_list() {
    python3 -c "
import json
with open('$HANDOFF_DEVICES', 'r') as f:
    data = json.load(f)
for d in data['devices']:
    sessions = ';'.join(d.get('sessions', ['*']))
    ro = 'read-only' if d.get('read_only') else 'read/write'
    exp = d.get('soft_expiry', 'never')
    last = d.get('last_seen') or 'never'
    renewal = 'true' if d.get('renewal_requested') else 'false'
    print(f\"{d['fingerprint']}|{d['name']}|{d['status']}|{sessions}|{ro}|{exp}|{last}|{renewal}\")
"
}

# Get the SHA256 fingerprint of a public key file
device_fingerprint() {
    local pub_key_file="$1"
    ssh-keygen -l -E sha256 -f "$pub_key_file" | awk '{print $2}'
}

# Generate a per-device Ed25519 key pair in HANDOFF_KEYS_DIR
# Returns the fingerprint
generate_device_key() {
    local key_name="$1"
    local key_path="$HANDOFF_KEYS_DIR/$key_name"
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "handoff:$key_name" -q
    device_fingerprint "${key_path}.pub"
}

# Add a device's public key to authorized_keys with forced command
add_device_to_authorized_keys() {
    local fingerprint="$1" pub_key_file="$2" hard_expiry="$3" device_label="$4"
    local pubkey
    pubkey=$(cat "$pub_key_file")
    # Resolve handoff binary: prefer installed, fall back to the script that sourced us
    local handoff_bin
    handoff_bin=$(which handoff 2>/dev/null || echo "")
    if [[ -z "$handoff_bin" || ! -x "$handoff_bin" ]]; then
        # Find the bin/handoff relative to this lib file
        local lib_dir
        lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        handoff_bin="$(cd "$lib_dir/../bin" 2>/dev/null && pwd)/handoff"
    fi
    if [[ ! -x "$handoff_bin" ]]; then
        handoff_bin="/usr/local/bin/handoff"
    fi
    # Format: command="...",restrict,pty,expiry-time="YYYYMMDD" <pubkey>
    local expiry_date
    expiry_date=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$hard_expiry" +%Y%m%d 2>/dev/null || echo "")
    local line
    if [[ -n "$expiry_date" ]]; then
        line="command=\"${handoff_bin} gate ${fingerprint}\",restrict,pty,expiry-time=\"${expiry_date}\" ${pubkey}"
    else
        line="command=\"${handoff_bin} gate ${fingerprint}\",restrict,pty ${pubkey}"
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    echo "$line" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
}

# Remove a device's key from authorized_keys by fingerprint
remove_device_from_authorized_keys() {
    local fingerprint="$1"
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        grep -v "$fingerprint" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp" || true
        mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
    fi
}

# Check if a session name matches any of the given glob patterns
# Usage: session_matches_patterns session_name pattern1 pattern2 ...
session_matches_patterns() {
    local session_name="$1"
    shift
    local pattern
    for pattern in "$@"; do
        # shellcheck disable=SC2254
        if [[ "$session_name" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Generate a random hex nonce (12 chars = 6 bytes)
generate_nonce() {
    openssl rand -hex 6
}

# Derive a 6-digit verification code from fingerprint + nonce
derive_verification_code() {
    local fingerprint="$1" nonce="$2"
    local material
    material=$(printf '%s%s' "$fingerprint" "$nonce" | shasum -a 256 | awk '{print $1}')
    local num
    num=$(printf '%d' "0x${material:0:8}")
    printf '%06d' $(( num % 1000000 ))
}

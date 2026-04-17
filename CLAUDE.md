# CLAUDE.md

## Project: Handoff

Open-source tool to seamlessly continue Mac terminal sessions on your phone.

## Architecture

Two components:

### 1. Mac CLI (`handoff`)
- `handoff setup` - one-time: install/start Tailscale, enable SSH, configure iTerm2 tmux -CC integration, generate SSH key
- `handoff` - show active tmux sessions with window count, ensure Tailscale is up, show connection info
- `handoff pair` - show QR code for phone setup (contains setup script URL + SSH key + Tailscale IP)
- `handoff status` - is sharing active?

### 2. Android app (native)
- Jetpack Compose UI with CameraX QR scanning for pairing
- Tailscale embedded via tsnet (Go library compiled to .aar via gomobile) - no separate VPN app needed
- One-time Tailscale auth: opens browser for login, state persisted for future launches
- SSH via JSch through a local TCP proxy that routes through tsnet to the Mac
- Dynamic session discovery: SSH into Mac, list tmux sessions, pick one, attach
- If only one session exists, skip picker and connect directly
- Terminal emulation via embedded Termux terminal libraries

## Key Technical Decisions

### tmux is invisible on Mac
- iTerm2's `tmux -CC` control mode makes tmux native - each tmux window becomes an iTerm2 tab
- Users type `claude`, `vim`, etc. as normal - nothing changes about their workflow
- Configured via iTerm2 profile "Send text at start": `tmux -CC new -A -s main`
- Alternative for non-iTerm2 users: `[[ -z "$TMUX" ]] && exec tmux new -A -s main` in .zshrc

### Tailscale for networking
- WireGuard-based, peer-to-peer encrypted, no open ports
- Works across different networks (home, office, mobile)
- Zero config after initial setup
- Free tier is sufficient
- Embedded in the Android app via tsnet (userspace networking) - no separate Tailscale app required
- Uses gomobile to compile Go tsnet library into an Android .aar
- Doesn't use Android VpnService, so it doesn't conflict with other VPNs

### Native Android app (not Termux)
- Native Jetpack Compose app with embedded Termux terminal libraries
- Full control over the UX end-to-end
- Tailscale networking built in - one fewer app to install
- QR code pairing with one-time Tailscale browser auth

### QR code for pairing
- Mac generates QR via `qrencode -t ANSIUTF8` (brew install qrencode)
- QR contains JSON payload: `{"v":1, "ip":"<tailscale_ip>", "user":"...", "key":"<base64_ssh_key>", "tmux":"<tmux_path>"}`
- Android app scans QR with CameraX + ML Kit, saves config, starts Tailscale auth flow

### Multi-session support
- Users may have multiple tmux sessions (different projects)
- `handoff` lists all active sessions with window counts
- Phone widget shows session picker
- Single session = auto-connect (skip picker)

## Dependencies

### Mac
- tmux (brew install tmux)
- Tailscale (brew install tailscale)
- qrencode (brew install qrencode) - for QR code generation
- macOS Remote Login (SSH) enabled

### Phone (Android)
- Handoff native app (all dependencies bundled):
  - Tailscale networking via embedded tsnet (gomobile .aar)
  - SSH via JSch + BouncyCastle (Ed25519 support)
  - Terminal emulation via embedded Termux libraries
  - CameraX + ML Kit for QR scanning
- Tailscale account (free tier) for authentication
- Android NDK required for building the tsnet .aar (build-time only)

## Package format
- Homebrew tap for Mac distribution
- Android APK (native app with embedded Tailscale)
- Go bridge built via gomobile: `cd android/gobridge && ./build-aar.sh`

## Permission Layers (v2)

### Per-device identity
- Each `handoff pair` generates a unique Ed25519 key per device
- Device registry at `~/.handoff/devices.json` tracks all paired devices
- Device identified by SSH key fingerprint (SHA256:...)
- Device name auto-detected from Android `Build.MODEL`

### SSH forced command (`handoff gate`)
- All device SSH keys use `command="handoff gate <fingerprint>"` in authorized_keys
- Phone can never execute arbitrary commands — only gate protocol commands
- Protocol: `list`, `windows <session>`, `attach <session> [window]`, `create-session`, `kill-session`, `create-window`, `kill-window`, `pair`, `renew`
- Gate enforces all permissions server-side: session filtering, read-only, expiry

### Device lifecycle
```
PENDING → (verification) → ACTIVE → (expiry) → SOFT_EXPIRED → (renew) → ACTIVE
                                   → (revoke) → removed
```

### Two-tier expiry
- **Soft expiry**: enforced in `handoff gate`, blocks list/attach, allows only `renew`
- **Hard expiry**: SSH `expiry-time` in authorized_keys = soft + 48h, key truly dies
- 48h grace window between soft and hard allows phone to request renewal

### Pairing verification
- Both Mac and phone derive a 6-digit code from `SHA256(fingerprint + nonce)`
- Mac user must confirm codes match before device is activated
- 60-second timeout with automatic cleanup on rejection/timeout

### Device management
- `handoff devices` — list all paired devices with status
- `handoff devices rm/edit/renew/log` — manage permissions, approve renewals, view audit log
- Access log at `~/.handoff/access.log` (JSON lines, every gate invocation)

### Android security
- v2 QR payloads include `device_name` and `nonce` for verification
- `SshManager` speaks gate protocol (falls back to raw tmux for v1)
- `GateException` for structured error handling from gate responses
- Read-only mode hides create/kill UI controls
- Biometric lock (Phase 8): SSH key in Android Keystore with hardware-backed biometric binding

## Open questions
- iOS support? Blink Shell is the best iOS terminal but it's not open source. Could still provide instructions.
- Should we also support Linux hosts (not just Mac)?
- Notification on phone when `handoff` is run? (Termux:API can show notifications)
- Auto-detect when user leaves Mac (lid close, screen lock) and trigger handoff automatically?

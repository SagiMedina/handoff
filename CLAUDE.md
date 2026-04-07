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

### 2. Phone side (Termux script + widget)
- Setup script (delivered via QR code from `handoff pair`)
- Termux:Widget integration for home screen one-tap access
- Dynamic session discovery: SSH into Mac, list tmux sessions, pick one, attach
- If only one session exists, skip picker and connect directly

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

### Termux (not Termius) on phone
- Open source - we control the entire UX end-to-end
- Termux:Widget allows home screen shortcuts (one-tap connect)
- Can ship scripts that automate the full flow
- F-Droid distribution

### QR code for pairing
- Mac generates QR via `qrencode -t ANSIUTF8` (brew install qrencode)
- QR contains setup one-liner for Termux
- Handles: SSH key transfer, Tailscale IP discovery, shortcut installation
- `ssh://` URI scheme works but doesn't support tmux attach - so we use our own script

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
- Termux (from F-Droid)
- Termux:Widget (from F-Droid) - for home screen shortcuts
- Tailscale (from Play Store)
- openssh (pkg install openssh in Termux)

## Package format
- Homebrew tap for Mac distribution
- Shell script for Termux side
- Consider: could also be a Rust CLI for portability

## Open questions
- iOS support? Blink Shell is the best iOS terminal but it's not open source. Could still provide instructions.
- Should we also support Linux hosts (not just Mac)?
- Notification on phone when `handoff` is run? (Termux:API can show notifications)
- Auto-detect when user leaves Mac (lid close, screen lock) and trigger handoff automatically?

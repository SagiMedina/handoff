# Play Store Listing

## Short description (80 chars max)

Continue your Mac terminal sessions on your phone — seamlessly, securely.

## Full description

Handoff lets you pick up your Mac terminal sessions right where you left them — from your phone. Walk away from your desk and keep working.

How it works:
1. Run `handoff pair` on your Mac
2. Scan the QR code with the app
3. Your terminal sessions appear on your phone

Your Mac terminal tabs show up as sessions you can tap into. Running Claude Code, vim, a dev server, or SSH? It's all there, exactly as you left it.

Built for developers who don't want to stop working just because they stood up.

Key features:
- Instant session discovery — all your tmux sessions and tabs, one tap away
- Secure by default — peer-to-peer encrypted connection via Tailscale (WireGuard)
- No port forwarding, no exposed servers, no cloud relay
- Works across any network — home, office, coffee shop, mobile data
- Native terminal emulator with full keyboard support
- One-time setup, zero daily friction

Technical details:
- Uses tmux on your Mac (invisible via iTerm2's tmux integration)
- Connects over Tailscale's WireGuard mesh network
- SSH authentication with Ed25519 keys
- All credentials stored locally in Android encrypted storage
- Tailscale networking embedded — no extra VPN app needed
- Open source: github.com/SagiMedina/handoff

Requirements:
- Mac with tmux and Tailscale installed
- Free Tailscale account

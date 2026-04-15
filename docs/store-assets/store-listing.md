# Play Store Listing

## Short description (80 chars max)

Continue Claude Code, Codex & Gemini CLI sessions from Mac to phone.

## Full description

Your AI coding agent is mid-task on your Mac. You need to leave your desk. What now?

Handoff. Open your phone, tap the session, and you're back — cursor blinking, context intact, agent still running.

Works with every terminal tool:
• Claude Code — see it think, approve edits, keep prompting
• OpenAI Codex CLI — full TUI, right on your phone
• Gemini CLI — same session, different screen
• vim, ssh, docker, git — anything running in tmux

How it works:
1. Run "handoff pair" on your Mac
2. Scan the QR code
3. All your terminal sessions appear on your phone — tap to connect

No cloud relay. No port forwarding. Your Mac and phone talk directly over an encrypted WireGuard tunnel via Tailscale. Your terminal data never touches a third-party server.

Why developers love it:
• Walk away from your desk without killing a long-running agent
• Check on a build from the couch
• Approve a Claude Code edit from your phone while grabbing coffee
• Monitor logs on the go
• Pair once, connect instantly every time after

Security:
• Peer-to-peer encrypted (WireGuard via Tailscale)
• Ed25519 SSH keys stored in Android encrypted storage
• Per-device identity with server-side permission control
• Biometric lock option for SSH key access
• Tailscale embedded — no extra VPN app needed
• Open source: github.com/SagiMedina/handoff

Setup takes 2 minutes:
• Mac: brew install handoff (tmux + Tailscale required)
• Phone: scan QR, authenticate Tailscale once, done
• Free Tailscale account is all you need

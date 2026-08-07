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
- `handoff notify --type ... --message ...` - push a notification to paired phones; tool-agnostic (any source can call it; the Claude Code plugin is one example)

### 2. Android app (native)
- Jetpack Compose UI with CameraX QR scanning for pairing
- Tailscale embedded via tsnet (Go library compiled to .aar via gomobile) - no separate VPN app needed
- One-time Tailscale auth: opens browser for login, state persisted for future launches
- SSH via JSch through a local TCP proxy that routes through tsnet to the Mac
- Dynamic session discovery: SSH into Mac, list tmux sessions, pick one, attach
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
- Phone widget shows session picker (always — never auto-connects)

### Phone notification bridge
- Mac → phone push pipeline that reuses the existing per-device SSH/gate channel — no new ports, no FCM, no third-party push service.
- `handoff notify` (generic CLI) appends an NDJSON event to `~/.handoff/events.jsonl` (atomic, monotonic id via `~/.handoff/events.id`, rotation-bounded at ~1 MB).
- `handoff gate subscribe [since=<id>] [types=<csv>]` (new gate subcommand) opens a long-lived NDJSON stream over the existing SSH session via `lib/handoff-events-stream.py` — drains events past the cursor, then tails the log forever, with 25 s heartbeats and rotation-aware inode polling. Gate filters by the device's session patterns (same matcher as `list`/`attach`).
- Android `HandoffConnectionService` owns a long-lived `NotificationSubscriber` (its own JSch session, separate from `SshManager` because that one isn't idempotent). Posts events on a HIGH-importance `handoff_events` channel. A `BootReceiver` (manifest: `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED`) restarts the service automatically after reboot or APK upgrade so the subscriber wakes up without the user reopening the app.
- Per-tab dedupe: notification id = `("$tmux_session:$tmux_window").hashCode() & 0x3FFFFFFF`. Re-posting with the same id replaces in place — newer events for the same tab supersede older ones rather than stack.
- Active-tab suppression: `ForegroundState` tracks `isForeground` (ActivityLifecycleCallbacks), `currentRoute` (NavController listener), `activeTerminalTab` (TerminalScreen DisposableEffect). Suppression fires only when all three say "user is currently looking at this exact tab"; the cursor still advances so the event is "delivered" in the UX sense.
- Deep-link: tap → `MainActivity.onNewIntent` → `navController.navigate("terminal/$s/$w")`.
- The Claude Code plugin (`claude-plugin/handoff-notify/`) is the canonical *event source*, not the only one. Anything that wants to ping the phone (CI, build scripts, a future `handoff watch-exit <cmd>` wrapper) calls `handoff notify` directly. Distribution: Claude Code plugin ships via `/plugin install`; `handoff` itself ships via Homebrew. Two separate channels — never coupled in `handoff setup`.

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
- Protocol: `list`, `windows <session>`, `attach <session> [window]`, `create-session`, `kill-session`, `create-window`, `kill-window`, `pair`, `renew`, `subscribe`
- Gate enforces all permissions server-side: session filtering, read-only, expiry
- `subscribe` is read-only and respects soft expiry like other commands; emits NDJSON (one event per line) plus a `{"type":"ping"}` heartbeat every 25 s and a `{"type":"ready","last_id":N}` marker after the initial drain

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

## Known gaps
- **`brew install handoff` does not work yet.** `Formula/handoff.rb` has `sha256 "PLACEHOLDER"`, no tap is published, the v0.1.0 release tag isn't on GitHub, and neither the formula nor `install.sh` includes the new `lib/handoff-events-stream.py` (the gate `subscribe` helper). To make brew real: fill the SHA, tag a release, publish a `SagiMedina/homebrew-handoff` tap repo, and update both `Formula/handoff.rb` and `install.sh` to install the helper. README's `brew install handoff` line is currently aspirational; today users must `git clone && ./install.sh` (and even that misses the helper — fix install.sh too).
- **Claude Code plugin is not installable from a non-public repo via the marketplace yet.** `/plugin marketplace add SagiMedina/handoff` requires the repo to be on GitHub. Until then, the manual fallback (`forward.sh` referenced from absolute path inside `~/.claude/settings.json` `hooks` block) is the only working path. `extraKnownMarketplaces` with `source: "local"` is rejected by the user-scope settings validator — do not retry that route.

# Handoff iOS Client

iOS companion app for [Handoff](../README.md) — continue your Mac terminal sessions on your iPhone/iPad.

## Requirements

- macOS with **Xcode 16.1+**
- **Go** (https://go.dev/dl/) — needed to build TailscaleKit (libtailscale's Swift framework)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- iOS 16.0+ deployment target
- An Apple ID (free personal team works for development; paid for App Store distribution)

## Setup

1. **Install prerequisites**
   ```bash
   brew install xcodegen
   # Go: install from https://go.dev/dl/ if not already present
   go version   # verify
   ```

2. **Build TailscaleKit.xcframework** (embedded Tailscale networking — no separate VPN app needed):
   ```bash
   cd ios
   ./scripts/build-tailscalekit.sh
   ```
   Clones [Tailscale's `libtailscale`](https://github.com/tailscale/libtailscale), runs `make ios-fat`, and installs `Handoff/Frameworks/TailscaleKit.xcframework` (~70 MB, not checked in).

3. **Find your Apple Developer Team ID**
   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject | grep -oE 'OU=[A-Z0-9]+' | sed 's/OU=//'
   ```
   If no certificate is found, open Xcode once → Settings → Accounts → sign in with your Apple ID, then retry.

4. **Generate the Xcode project** with your team and bundle ID prefix:
   ```bash
   DEVELOPMENT_TEAM=YOURTEAMID \
   BUNDLE_ID_PREFIX=dev.yourname.handoff \
     ./scripts/generate.sh
   ```

   For **simulator-only** builds you can leave `DEVELOPMENT_TEAM` empty:
   ```bash
   BUNDLE_ID_PREFIX=dev.yourname.handoff ./scripts/generate.sh
   ```

5. **Open in Xcode** and build:
   ```bash
   open Handoff/Handoff.xcodeproj
   ```

   Or build from the command line:
   ```bash
   cd Handoff
   xcodebuild -scheme Handoff -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
   ```

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — Terminal emulator (SPM)
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) — SSH client (SPM)
- [TailscaleKit](https://github.com/tailscale/libtailscale) — Tailscale's official iOS framework (vendored xcframework). SSH dials through the Tailscale node's SOCKS5 loopback proxy via a custom NIO handler.

## Architecture

```
Sources/
├── App/            HandoffApp, ContentView (NavigationStack), Theme
├── Models/         ConnectionConfig, TmuxSession, TmuxWindow, QRCodePayload
├── Services/       ConfigStore (Keychain), SSHManager (NIOSSH),
│                   TerminalChannel (PTY), TerminalSessionStore (lifecycle),
│                   TailscaleManager (TailscaleKit wrapper),
│                   SOCKS5AuthHandler (NIO SOCKS5 + RFC 1929 username/password)
└── Views/          Welcome, TailscaleAuth, Scan, QRScannerController,
                    Sessions, SessionCard, Terminal, SwiftTermView, MobileToolbar
```

## Pairing

1. On your Mac: `handoff pair` — prints a QR code
2. On your phone: open the Handoff app → sign in to Tailscale (one-time, in browser) → tap **Scan QR Code** → point at the QR on your Mac
3. The app parses the JSON payload, saves the SSH private key to iOS Keychain, and lists your tmux sessions
4. Tap a session → you're attached live

## Notes

- **The generated `.xcodeproj` is not checked in** — regenerate it locally with `./scripts/generate.sh` any time you change `project.yml`
- **The `TailscaleKit.xcframework` is not checked in** (~70 MB) — rebuild with `./scripts/build-tailscalekit.sh` after cloning
- `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` are intentionally kept out of source control so the repo stays team-agnostic
- For simulator testing without camera access, there's a `Debug: Paste QR Payload` button on the Welcome screen (DEBUG builds only)

# Handoff iOS Client

iOS companion app for [Handoff](../README.md) — continue your Mac terminal sessions on your iPhone/iPad.

## Requirements

- macOS with **Xcode 15+**
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- iOS 16.0+ deployment target
- An Apple ID (free personal team works for development; paid for App Store distribution)

## Setup

1. **Install XcodeGen**
   ```bash
   brew install xcodegen
   ```

2. **Find your Apple Developer Team ID**
   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject | grep -oE 'OU=[A-Z0-9]+' | sed 's/OU=//'
   ```
   If no certificate is found, open Xcode once → Settings → Accounts → sign in with your Apple ID, then retry.

3. **Generate the Xcode project** with your team and bundle ID prefix:
   ```bash
   cd ios
   DEVELOPMENT_TEAM=YOURTEAMID \
   BUNDLE_ID_PREFIX=dev.yourname.handoff \
     ./scripts/generate.sh
   ```

   For **simulator-only** builds you can leave `DEVELOPMENT_TEAM` empty:
   ```bash
   BUNDLE_ID_PREFIX=dev.yourname.handoff ./scripts/generate.sh
   ```

4. **Open in Xcode** and build:
   ```bash
   open Handoff/Handoff.xcodeproj
   ```

   Or build from the command line:
   ```bash
   cd Handoff
   xcodebuild -scheme Handoff -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
   ```

## Dependencies (via SPM)

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — Terminal emulator
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) — SSH client

## Architecture

```
Sources/
├── App/            HandoffApp, ContentView (NavigationStack), Theme
├── Models/         ConnectionConfig, TmuxSession, TmuxWindow, QRCodePayload
├── Services/       ConfigStore (Keychain), SSHManager (NIOSSH),
│                   TerminalChannel (PTY), TerminalSessionStore (lifecycle)
└── Views/          Welcome, Scan, QRScannerController, Sessions, SessionCard,
                    Terminal, SwiftTermView, MobileToolbar
```

## Pairing

1. On your Mac: `handoff pair` — prints a QR code
2. On your phone: open the Handoff app → tap **Scan QR Code** → point at the QR on your Mac
3. The app parses the JSON payload, saves the SSH private key to iOS Keychain, and lists your tmux sessions
4. Tap a session → you're attached live

## Notes

- **The generated `.xcodeproj` is not checked in** — regenerate it locally with `./scripts/generate.sh` any time you change `project.yml`
- `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` are intentionally kept out of source control so the repo stays team-agnostic
- For simulator testing without camera access, there's a `Debug: Paste QR Payload` button on the Welcome screen (DEBUG builds only)

# Handoff iOS Client

iOS companion app for [Handoff](../README.md) — continue your Mac terminal sessions on your iPhone/iPad.

## Requirements

- macOS with Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- iOS 16.0+ deployment target

## Setup

```bash
# Generate the Xcode project
./scripts/generate.sh

# Open in Xcode
open Handoff/Handoff.xcodeproj
```

Then build and run on a simulator or device.

## Dependencies (via SPM)

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — Terminal emulator
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) — SSH client

## Architecture

```
Sources/
├── App/            # App entry point, navigation, theme
├── Models/         # ConnectionConfig, TmuxSession, TmuxWindow, QR payload
├── Services/       # ConfigStore (Keychain), SSHManager
└── Views/          # Welcome, Scan, Sessions, Terminal screens
```

## Pairing

1. On your Mac: `handoff pair`
2. On your phone: open app → Scan QR Code
3. Select a tmux session → you're in

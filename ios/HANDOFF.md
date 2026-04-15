# Handoff iOS — Continuation Context

Compact handoff document for continuing work on the iOS client. Covers what exists, how to work on it, and what's needed to reach App Store.

## Project at a glance

**What it is.** Open-source tool (original author: Sagi Medina) that lets you continue your Mac terminal sessions on a phone. Mac CLI (bash) + Android app (Kotlin/Compose) + iOS app (SwiftUI/SwiftNIO SSH/TailscaleKit — **this is us**). Pairing via QR code containing Ed25519 SSH key + Tailscale IP. Terminal rendering via embedded terminal emulator (Termux libs on Android, SwiftTerm on iOS).

**Repo.** `/Users/omri.a/Code/handoff` — fork of `SagiMedina/handoff`. Our fork: `omriariav/handoff`. Upstream is where we PR.

## Current state

- PR #1 (iOS client skeleton) — **merged**
- PR #2 (app icons for iOS + Android) — **merged**
- PR #3 (embedded Tailscale via TailscaleKit + UI polish + Sign out) — **open, awaiting Sagi review**, codex approved. Branch: `ios-tailscale-polish`.

Working build on iPhone 17 Pro / iOS 26.3.1 / Xcode 26.4. Embedded Tailscale, SOCKS5 tunnel, SSH, SwiftTerm terminal, session/tab/kill/new all working end-to-end.

## Collaboration model (AMQ)

Three agent sessions coordinated via [AMQ](https://github.com/avivsinai/agent-message-queue). Always use `--session` when crossing streams.

| Stream | Handle | Role |
|---|---|---|
| stream1 | codex | Senior architect — code review, design decisions, library recommendations |
| stream2 | claude | This session — drives dev, writes code, builds, deploys |
| stream3 | claude | Product designer — UX calls, visual design, design audits |

Example:
```
amq send --to codex --session stream1 --kind question --body "..."
amq send --to claude --session stream3 --kind question --body "UX: where to put X?"
```

**Always consult codex for strategic/architectural decisions.** Have her review PRs before they land. See `/Users/omri.a/.handoff-product-designer.md` for the designer persona prompt.

## Code layout

```
ios/Handoff/
├── project.yml                  # XcodeGen spec. BUNDLE_ID_PREFIX + DEVELOPMENT_TEAM via env.
├── Resources/
│   ├── Info.plist               # Camera permission string, etc.
│   ├── Assets.xcassets/AppIcon.appiconset/  # "Terminal Kinetics" chevron icon (light/dark/tinted)
│   └── JetBrainsMono-Regular.ttf
├── Frameworks/
│   └── TailscaleKit.xcframework (not in git — built locally)
└── Sources/
    ├── App/
    │   ├── HandoffApp.swift             # @StateObject TailscaleManager + ConfigStore at root
    │   ├── ContentView.swift            # Routing: Welcome → TailscaleAuth → Sessions → Terminal
    │   └── Theme.swift                  # Dark GitHub palette
    ├── Models/
    │   ├── ConnectionConfig.swift       # ip/user/privateKey(base64)/tmuxPath
    │   ├── TmuxSession.swift / TmuxWindow.swift   # TmuxWindow has cwd field
    │   └── QRCodePayload.swift          # JSON parser for `handoff pair` payload
    ├── Services/
    │   ├── ConfigStore.swift            # Keychain (SSH key) + UserDefaults (metadata)
    │   ├── TailscaleManager.swift       # @MainActor ObservableObject, TailscaleKit wrapper,
    │   │                                # state machine, generation counter, runtime box
    │   ├── SSHManager.swift             # NIOSSH client, OpenSSH key parser, proxy-aware connect
    │   ├── SOCKS5AuthHandler.swift      # Custom RFC 1929 SOCKS5 client + PostSOCKSUpgrader
    │   ├── TerminalChannel.swift        # PTY-backed SSH exec channel for tmux attach
    │   └── TerminalSessionStore.swift   # @MainActor singleton cache for live terminals
    └── Views/
        ├── WelcomeView.swift            # First launch + DEBUG "Paste QR payload" for simulator
        ├── ScanView.swift + QRScannerController.swift   # AVFoundation QR scanner
        ├── TailscaleAuthView.swift      # Browser sign-in via SFSafariViewController (.sheet)
        ├── SessionsView.swift           # Session list + "● Connected" menu (Copy IP / Sign out)
        ├── SessionCard.swift            # Long-press to kill session, tabs with cwd, dashed "+ new tab"
        ├── TerminalView.swift + MobileToolbar.swift     # SwiftTerm + 2-row extra keys
        └── SwiftTermView.swift          # UIViewRepresentable around SwiftTerm
```

### Key architectural decisions (do not revisit lightly)

1. **Embedded Tailscale via TailscaleKit, not gomobile+tsnet.** Gomobile tsnet doesn't work on iOS without NetworkExtension (paid Apple Developer Program). TailscaleKit (tailscale/libtailscale) is Tailscale's supported iOS framework. See `build-tailscalekit.sh` pinned to a specific commit.
2. **SSH tunnels through TailscaleKit's SOCKS5 loopback.** TailscaleKit exposes a local SOCKS5 server with username/password auth. NIOSOCKS doesn't implement username/password, so `SOCKS5AuthHandler.swift` is our hand-rolled RFC 1929 client. `PostSOCKSUpgrader` installs NIOSSHHandler SYNCHRONOUSLY via `pipeline.syncOperations` after the SOCKS handshake — critical because SOCKS5 handler fires leftover bytes immediately after firing its EstablishedEvent.
3. **Browser auth via SFSafariViewController (.sheet).** `UIApplication.shared.open(url)` backgrounds the app; iOS kills us within ~10s, taking tsnet down. SFSafariViewController keeps us foregrounded.
4. **TailscaleManager hoisted to HandoffApp.** If it lived in ContentView, SwiftUI identity churn could release it (and the TailscaleNode with it). Runtime pieces (node/localAPI/processor) collapsed into one `TailscaleRuntime` reference-type box for clean ARC.
5. **Generation counter on TailscaleManager.** Bumped on every start()/stop(); stale bus callbacks check it before mutating state. Prevents old generation events from clobbering new state.
6. **State+proxyConfig set atomically.** In one `MainActor.run` block so SessionsView reacting to `.connected` always sees a populated `proxyConfig`.
7. **NIOSSHHandler reference held directly, not queried from pipeline.** In the SOCKS5 path, NIOSSH isn't in the pipeline until PostSOCKSUpgrader installs it — `pipeline.handler(type:)` would race. We keep the reference we constructed.

## How to build

```bash
cd /Users/omri.a/Code/handoff/ios

# First time or after libtailscale bump:
./scripts/build-tailscalekit.sh      # builds TailscaleKit.xcframework (~70 MB, not checked in)

# Regenerate .xcodeproj any time project.yml changes:
DEVELOPMENT_TEAM=W6SR2D4HWY BUNDLE_ID_PREFIX=dev.omriariav.handoff ./scripts/generate.sh

# Build for simulator:
cd Handoff && xcodebuild -scheme Handoff -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Build for device:
cd Handoff && xcodebuild -scheme Handoff -destination 'id=<UDID>' -allowProvisioningUpdates build

# Omri's device UDID: 00008150-000865C63A01401C
# DEVELOPMENT_TEAM: W6SR2D4HWY (Omri's personal Apple ID team)
```

### Deploy to device + stream logs

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/Handoff-*/Build/Products/Debug-iphoneos -name "Handoff.app" -type d | head -1)
xcrun devicectl device install app --device 00008150-000865C63A01401C "$APP"
xcrun devicectl device process launch --terminate-existing --console --device 00008150-000865C63A01401C dev.omriariav.handoff.Handoff
```

If launch fails with "invalid code signature / profile not trusted", on phone: **Settings → General → VPN & Device Management → [Apple ID] → Trust**.

If phone locked: unlock before `--console` launch or it errors.

### Test pairing without a physical Mac setup

DEBUG builds have "Debug: Paste QR Payload" on WelcomeView. Generate the JSON with:
```bash
IP=$(tailscale ip -4 | head -1)
USER=$(whoami)
KEY=$(base64 < ~/.handoff/phone_key | tr -d '\n')
TMUX=$(which tmux)
printf '{"v":1,"ip":"%s","user":"%s","key":"%s","tmux":"%s"}' "$IP" "$USER" "$KEY" "$TMUX" | pbcopy
```
Paste into the sim.

## Sagi's progress — what to track

Upstream main: `git fetch upstream && git log upstream/main --oneline`. Any new Sagi commits affecting Android or Mac CLI may need iOS porting. Precedents:

- `b4263cc` — Embedded Tailscale + new session creation (ported via PR #3)
- `fe44e48` — New window per session (ported via PR #1)
- `0e947d4` — Session/window management + auto-refresh (ported via PR #1)
- `967587d` — Sessions UI polish (cwd per tab, window→tab rename, long-press header) (ported via PR #3)
- `e92357e / d24a8ec / 795c7d9` — Play Store release prep (Android-only, nothing to port)

Workflow for new Sagi commits:
1. `git fetch upstream`
2. For each Android commit, identify iOS deltas (new SSH commands, new UI patterns)
3. If significant: ask codex for review before touching SSH/TailscaleManager
4. Update iOS to match UX on UI changes (ask stream3 designer for layout calls)
5. PR with proper cross-reference to Sagi's commit

## Known TODO / pending work

### From product designer's audit (2026-04-11) — still open
14 High-severity items not yet addressed:
- **WelcomeView**: CTA contrast fails WCAG AA (white on #58A6FF). Tappable `handoff pair` command (copy to clipboard).
- **ScanView**: torch toggle, responsive viewfinder size, success haptic + green flash.
- **SessionsView**: needs "N tabs" label in header, connection-drop indicator when SSH goes down.
- **SessionCard**: tap targets still shy of 44pt iOS HIG minimum.
- **TerminalView**: Dynamic Type scaling for terminal font, copy/paste menu, connection-state indicator, friendlier nav title.
- **MobileToolbar**: 38pt buttons below 44pt HIG, no haptics, no chip backgrounds on keys, modifier keys don't apply to system keyboard input.

### Architectural
- **System-keyboard modifier pass-through** for CTRL/ALT keys (codex + designer design doc pending)
- **Host-key verification** — currently accepts all host keys (MVP). Needs user-facing fingerprint TOFU.
- **Session kill cleanup race** — closing last terminal doesn't always clear `isIdleTimerDisabled` if multiple sessions were open.

### Nice-to-have
- Pinch-to-zoom in terminal
- Pull-to-refresh on Sessions list
- Long-press alternates on toolbar keys (`-`→`|`, `/`→`\`)
- Session state persistence across app cold-start (currently requires reconnect)

## App Store publishing checklist

Currently **not shippable to App Store**. Gaps:

### Must have
- [ ] **Paid Apple Developer Program membership** ($99/yr). Omri is currently on a free Apple ID (Personal Team). Free team can only install to personally trusted devices; cannot submit to App Store. Enrollment takes ~48h.
- [ ] **Bundle ID registration** in Apple Developer portal. Currently `dev.omriariav.handoff.Handoff` via `BUNDLE_ID_PREFIX` env var. Pick a stable permanent ID before shipping.
- [ ] **App Store Connect listing** — app name (Handoff likely taken, may need "Handoff Terminal" or similar), primary category (Developer Tools or Utilities), subcategory.
- [ ] **Privacy labels** — required since 2020. Key declarations:
  - Contact Info (user name) — we collect SSH username for the tmux session; declare as "not linked to user".
  - User Content (other) — tmux session contents pass through but are never stored or transmitted to our servers.
  - Diagnostics — we log `[Tailscale]` and `[SSH]` prints to stdout in DEBUG only; none in release.
  - Network usage disclosed (expected).
- [ ] **`NSCameraUsageDescription`** in Info.plist — already present: *"Handoff needs camera access to scan the QR code from your Mac for pairing."* Verify still accurate for reviewer.
- [ ] **App icon** — shipped via the `AppIcon.appiconset` (PR #2 landed). Check that 1024×1024 has no transparency and no rounded corners (Apple applies those).
- [ ] **Launch screen** — currently Info.plist `UILaunchScreen: <dict/>` (default empty). Acceptable but a simple launch screen storyboard or a single-color screen with the app icon would be more polished.
- [ ] **Accessibility audit** — Dynamic Type, VoiceOver labels, color contrast. The designer flagged several gaps (see audit above).
- [ ] **Localization** — English only currently. App Store allows English-only but flag as limitation.
- [ ] **Privacy policy URL** — required if collecting any user data. Even though we don't, some categories still require a URL. Host a static page.
- [ ] **Support URL** — GitHub issues URL is fine.

### Review-triggering concerns (will get kicked back)
- [ ] **Description messaging** — do NOT frame as "download and execute code on the user's device." Apple reviewers reject apps framed as interpreters/code-execution. Frame as: "remote terminal client to a user-owned Mac over a private Tailscale network". Blink Shell, Termius, Prompt 3 are the precedents (all approved).
- [ ] **Tailscale sign-in** — reviewer will need a test account. Document in review notes.
- [ ] **Demo pairing flow** — provide either a dummy pairing payload or screenshots of the Mac `handoff pair` output so reviewer can reach Sessions screen without their own Mac setup.
- [ ] **SFSafariViewController** use is fine — standard pattern for third-party OAuth-style flows.
- [ ] **TailscaleKit** framework — vendored xcframework from Tailscale's open-source libtailscale. License is BSD-3-Clause, compatible with App Store distribution. Acknowledge in app's Acknowledgements screen (not built yet — follow-up).
- [ ] **SwiftTerm** — MIT licensed, App Store compatible. Same acknowledgement follow-up.

### Build / distribution
- [ ] **Archive build** via Xcode Product → Archive (currently only Debug builds). Validate, upload to App Store Connect.
- [ ] **TestFlight beta** before App Store review — validates provisioning, signing, entitlements under the paid program.
- [ ] **Encryption export compliance** — we use SSH and TLS. In Info.plist: `ITSAppUsesNonExemptEncryption: false` if we only use Apple's standard encryption APIs + published SSH/TLS libraries (which is our case). Submit annual self-classification report to BIS.
- [ ] **Screenshots** — App Store requires: 6.7" iPhone (required), 6.5" iPhone (optional), 5.5" iPhone (optional), and 12.9" iPad Pro (required if iPad supported). We currently target `TARGETED_DEVICE_FAMILY: "1,2"` (iPhone + iPad) — decide if iPad is in scope or drop to iPhone only.

### Post-launch hygiene
- [ ] **Crashlytics / crash reporting** — none today; add before large rollout.
- [ ] **Remote configuration** or feature flags for staged rollouts.
- [ ] **Release notes for App Store** — user-facing changelog.

## Git cheatsheet

Branch strategy: feature branches off main, PR against upstream SagiMedina/handoff.

```bash
# Sync with upstream
git fetch upstream
git checkout main && git merge upstream/main && git push

# Start new feature
git checkout -b feature-name

# Deploy cycle on device
cd ios/Handoff && xcodebuild -scheme Handoff -destination 'id=00008150-000865C63A01401C' -allowProvisioningUpdates build
APP=$(find ~/Library/Developer/Xcode/DerivedData/Handoff-*/Build/Products/Debug-iphoneos -name "Handoff.app" -type d | head -1)
xcrun devicectl device install app --device 00008150-000865C63A01401C "$APP"
```

## First thing a fresh session should do

1. `git status` — see current branch and any in-flight work
2. `git fetch upstream && git log upstream/main --oneline -10` — check for new Sagi commits
3. Read this file + the most recent few commits on the active branch
4. `amq who --json` — verify all three streams are alive; if not, you may be working solo

## Contacts / references

- **Upstream**: https://github.com/SagiMedina/handoff
- **Fork**: https://github.com/omriariav/handoff
- **TailscaleKit source**: https://github.com/tailscale/libtailscale (pinned: `5e89501def80a6579ca5d0f9a02f336be62b8f2e`)
- **SwiftTerm**: https://github.com/migueldeicaza/SwiftTerm (SPM, `from: 1.2.0`)
- **SwiftNIO SSH**: https://github.com/apple/swift-nio-ssh (SPM, `from: 0.8.0`)
- **Apple Developer Program enrollment**: https://developer.apple.com/programs/enroll/
- **App Store Connect**: https://appstoreconnect.apple.com
- **Review Guidelines**: https://developer.apple.com/app-store/review/guidelines/
- **Omri's Apple Dev Team ID**: `W6SR2D4HWY` (free Personal Team; upgrade for App Store)

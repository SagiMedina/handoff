---
name: Android App Terminal State
description: Current state of Handoff Android app terminal implementation — what works, what's broken, visual comparison with Termux, detailed next steps and debugging guide
type: project
---

# Handoff Android App — Terminal Implementation State (2026-04-09)

## Goal
Make the Handoff native Android app's terminal look and function **exactly** like Termux. The app connects to tmux sessions on a Mac via SSH and renders them in an embedded terminal view. The user has confirmed that connecting from the Termux app (via the `handoff` shell script) works perfectly — scrolling, keyboard, colors, zoom all work. Our native app must match that quality.

## Architecture Overview

The app embeds Termux's terminal libraries directly (MIT-licensed, copied from `termux-app` repo):
- **terminal-emulator**: `com.termux.terminal.*` — TerminalEmulator, TerminalBuffer, TerminalSession, etc.
- **terminal-view**: `com.termux.view.*` — TerminalView, TerminalRenderer, GestureAndScaleRecognizer

Key difference from Termux: instead of a local PTY process, our `TerminalSession.java` bridges SSH I/O streams to the TerminalEmulator. This is the only file that significantly differs from upstream.

**SSH library**: JSch (`com.github.mwiede:jsch:0.2.21`) + BouncyCastle for Ed25519 keys.

## Critical Difference: How Termux Connects vs How We Connect

### Termux (working perfectly)
The `handoff` shell script in Termux runs:
```bash
exec ssh -t "$SSH_HOST" "$TMUX_PATH attach -t '${SESSION_NAME}:${WIN_IDX}'"
```
This uses `ssh -t` which:
1. Allocates a PTY on the SSH side
2. Runs `tmux attach` as the **SSH command** directly (not in a shell)
3. Termux's TerminalSession creates a local PTY via JNI, SSH runs inside that PTY
4. The PTY handles all the I/O bridging natively

### Our App (broken)
In `SshManager.openShell()`:
```kotlin
val channel = sess.openChannel("shell") as ChannelShell  // Opens interactive shell
channel.setPtyType("xterm-256color", cols, rows, ...)
channel.connect(10_000)
// Then SENDS tmux attach as text input to the shell:
outputToRemote.write("$tmuxPath attach -t '${sessionName}:${windowIndex}'\n".toByteArray())
```
This opens a shell channel (like `ssh user@host` then typing), sends `tmux attach` as stdin text, and bridges the shell's I/O to our TerminalEmulator. This is **fundamentally different** from running a command directly.

### Why This Matters
- **Opening a shell first** means the user's shell startup (.zshrc, .bashrc) runs, which may conflict with tmux
- **Sending tmux attach as text** means there's a race condition — the shell prompt must be ready before we send the command
- **The shell wraps tmux**, so shell exit behavior, signal handling, and PTY management are different
- **This may be why it locks the Mac tmux session** — double-nesting shells or tmux clients

### Recommended Fix
Use `ChannelExec` instead of `ChannelShell`:
```kotlin
val channel = sess.openChannel("exec") as ChannelExec
channel.setPtyType("xterm-256color", cols, rows, ...)
channel.setCommand("$tmuxPath attach -t '${sessionName}:${windowIndex}'")
channel.connect(10_000)
```
This matches what `ssh -t host "tmux attach ..."` does — runs the command directly without an intermediate shell. This is closer to how Termux works and may fix both the locking and scrolling issues.

## What Works
- SSH connection via JSch with Ed25519 keys
- QR code scanning for pairing (JSON payload with ip, user, key, tmuxPath)
- Session/window listing via `tmux list-sessions` and `tmux list-windows`
- Terminal rendering with ANSI colors and escape sequences
- Keyboard input (after NetworkOnMainThread fix)
- `imePadding()` for keyboard — terminal resizes when keyboard shows
- Build succeeds: `./gradlew assembleDebug`

## What's Broken

### 1. SSH Connection Locks Mac tmux Session (CRITICAL)
Connecting from the app sometimes locks the user out of their tmux session on the Mac. Likely caused by our use of `ChannelShell` + sending `tmux attach` as text (see above).

### 2. Scrolling Doesn't Work
The TerminalView's `doScroll()` method detects that tmux uses alternate buffer (`isAlternateBufferActive()=true`) and mouse tracking (`isMouseTrackingActive()=true`). It sends mouse wheel escape codes via `sendMouseEvent()` → SSH output stream. The remote doesn't respond with scrolled content, or the response doesn't arrive/render. In Termux connecting via `handoff` script, scrolling works perfectly.

### 3. Terminal Visual Quality is Much Worse Than Termux

**Termux (the target)**:
- Clean, crisp rendering with proper font sizing
- tmux status bar visible at bottom
- Two rows of extra keys matching this layout:
  ```
  ESC  /  —  HOME  ↑  END  PGUP
  TAB  CTRL  ALT  ←  ↓  →  PGDN
  ```
  (The `—` key has `|` as popup on long-press)
- Pinch-to-zoom works
- Text selection works

**Our app**:
- Font size hardcoded: `setTextSize(28)` — may not be optimal
- Only one row of extra keys: `ESC TAB CTRL SCROLL ↑ ↓ → ← | ~ / -`
- Missing: HOME, END, PGUP, PGDN, ALT
- Custom Compose `MobileToolbar.kt` vs Termux's native `ExtraKeysView`

## Key Bug Found and Fixed: NetworkOnMainThreadException

`TerminalSession.write()` is called from the main thread (by TerminalEmulator processing escape sequences), but JSch's SSH output stream does network I/O. Android throws `NetworkOnMainThreadException`, which corrupts the stream, making all subsequent writes fail with "Already closed".

**Fix applied**: Writes now go through a `SingleThreadExecutor` in TerminalSession.java. This preserves write ordering while moving network I/O off the main thread. Also added SSH keepalive (`setServerAliveInterval(15000)`).

## File Inventory

### Our Code (Handoff-specific)
| File | Lines | Purpose |
|------|-------|---------|
| `app/.../ui/screens/TerminalScreen.kt` | 213 | Compose screen: creates TerminalView via AndroidView, manages SSH lifecycle |
| `app/.../data/SshManager.kt` | 130 | JSch SSH connection, tmux commands, exec channel (proxyPort support for tsnet) |
| `app/.../data/TailscaleManager.kt` | ~80 | Kotlin wrapper around Go tsnet bridge — StateFlow for state/authUrl, startProxy() |
| `app/.../ui/components/MobileToolbar.kt` | 118 | Custom extra keys toolbar (Compose Row with buttons) |
| `app/.../terminal/TerminalSession.java` | 185 | **Modified from upstream** — bridges SSH streams to TerminalEmulator |
| `app/.../data/ConnectionConfig.kt` | ~20 | Data classes: ConnectionConfig, TmuxSession, TmuxWindow |
| `app/.../data/ConfigStore.kt` | ~50 | DataStore persistence for connection config |
| `app/.../MainActivity.kt` | ~130 | Single activity, Compose NavHost with routes: welcome, scan, tailscale_auth, sessions, terminal |
| `app/.../ui/screens/TailscaleAuthScreen.kt` | ~130 | Tailscale auth flow: spinner, browser sign-in, error handling |
| `app/.../ui/screens/SessionsScreen.kt` | ~120 | Lists tmux sessions/windows, starts tsnet proxy before SSH |
| `app/.../ui/screens/ScanScreen.kt` | ~100 | CameraX + ML Kit QR scanner |
| `app/.../ui/screens/WelcomeScreen.kt` | ~30 | First launch screen |
| `app/.../ui/theme/Theme.kt` | ~30 | Dark terminal theme |
| `app/.../HandoffApp.kt` | ~15 | Application class |
| `gobridge/bridge.go` | ~200 | Go tsnet bridge — Start/StartProxy/Stop, auth URL detection, Android workarounds |
| `gobridge/go.mod` | — | Go module (tailscale.com v1.76.6 + x/mobile) |
| `gobridge/build-aar.sh` | — | Builds gobridge.aar via gomobile |

### Termux Code (Copied from upstream, identical except TerminalSession)
All files under `app/src/main/java/com/termux/` are **IDENTICAL** to the upstream Termux repo except:
- `TerminalSession.java` — completely rewritten for SSH (see diff section below)
- All other `.java` files (TerminalView, TerminalEmulator, TerminalRenderer, KeyHandler, etc.) are byte-for-byte identical to upstream

### Missing from upstream that we don't have
- `JNI.java` — Termux uses this for local PTY creation; we don't need it (SSH replaces it)
- `ExtraKeysView.java` (681 lines) — Termux's proper extra keys; we have simpler `MobileToolbar.kt`
- `ExtraKeysInfo.java`, `ExtraKeysConstants.java` — Extra keys data model

## TerminalSession.java — The Key Modified File

Our TerminalSession replaces Termux's PTY-based session with SSH stream bridging:

**Upstream Termux TerminalSession**:
- Creates a local PTY via `JNI.createSubprocess(shellPath, ...)`
- Reads from PTY FileDescriptor via FileInputStream
- Writes to PTY FileDescriptor via FileOutputStream → ByteQueue → writer thread
- Uses `mTerminalToProcessIOQueue` (ByteQueue) for main→process writes
- Uses `mProcessToTerminalIOQueue` (ByteQueue) for process→terminal reads

**Our TerminalSession**:
- Constructor takes only `TerminalSessionClient` (no shell path, no PTY)
- `initializeEmulator(cols, rows, cellWidth, cellHeight)` — creates TerminalEmulator with hardcoded 5000 transcript rows
- `setOutputStream(OutputStream os)` — sets the SSH output stream
- `startReading(InputStream inputStream)` — starts background thread reading SSH input
- Reader thread: reads SSH InputStream → writes to `mProcessToTerminalIOQueue` → posts MSG_NEW_INPUT to main handler
- Main handler: reads from queue → `mEmulator.append()` → `notifyScreenUpdate()`
- `write()`: copies data, submits to SingleThreadExecutor → writes to SSH OutputStream (off main thread)
- `writeCodePoint()`: simplified UTF-8 encoding using `String.getBytes(UTF_8)` instead of manual bit manipulation

**Key difference in write path**: Upstream uses a ByteQueue (`mTerminalToProcessIOQueue`) with a dedicated writer thread. We use a SingleThreadExecutor. Both achieve the same goal of moving writes off the main thread, but our approach was added as a fix for `NetworkOnMainThreadException` — the original code wrote directly on main thread which crashed.

## How to Debug

### ADB Setup
The phone is connected wirelessly via ADB:
```bash
adb devices  # Should show device
adb shell am start -n com.handoff.app/.MainActivity  # Launch app
```

### Build & Deploy
```bash
cd /Users/sagimedina/PycharmProjects/handoff/android
./gradlew assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Log Monitoring
```bash
adb logcat -c  # Clear logs
adb logcat | grep "Handoff"  # Watch live
```
Key log messages:
- `SSH connected via JSch` — SSH session established
- `Shell channel connected` — Shell channel opened
- `Sent attach cmd` — tmux attach command sent
- `SSH read N bytes` — Data received from SSH
- `Handler append N bytes` — Data forwarded to terminal emulator
- `SSH stream ended` — SSH input stream closed
- `TerminalSession.write failed: ...` — Write errors (the NetworkOnMainThread bug manifests here)

### Screenshot Comparison
```bash
adb exec-out screencap -p > /tmp/screenshot.png
```

### Tap/Swipe Simulation
```bash
adb shell input tap 540 680       # Tap coordinates (screen ~1080 wide)
adb shell input swipe 540 300 540 1000 500  # Swipe (x1,y1,x2,y2,durationMs)
adb shell input text "ls"         # Type text
adb shell input keyevent KEYCODE_BACK  # Press Back
```

### Comparing with Termux
To see the working reference:
```bash
adb shell am start -n com.termux/.app.TermuxActivity  # Launch Termux
# In Termux, type "handoff" + Enter to connect to Mac tmux
```
Then screenshot and compare with our app connecting to the same session.

### Key Debug Points
1. **SSH stream state**: Add logging to `TerminalSession.write()` — check for exceptions
2. **Scroll behavior**: Add logging to `TerminalView.doScroll()`:
   ```java
   Log.d("Handoff", "doScroll: rowsDown=" + rowsDown + " mouseTracking=" + mEmulator.isMouseTrackingActive() + " altBuffer=" + mEmulator.isAlternateBufferActive());
   ```
3. **Channel state**: Check `shellChannel.isClosed` and `shellChannel.isConnected` in SshManager
4. **Write round-trip**: Trace: scroll → doScroll → sendMouseEvent → write() → SSH → response → SSH read → append → notifyScreenUpdate

## Termux Reference Code
Cloned at `/tmp/termux-app` (shallow clone). If missing, re-clone:
```bash
git clone --depth 1 https://github.com/termux/termux-app.git /tmp/termux-app
```
Key paths:
- `terminal-emulator/src/main/java/com/termux/terminal/` — emulator library (our copy is identical)
- `terminal-view/src/main/java/com/termux/view/` — view library (our copy is identical)
- `terminal-emulator/src/main/java/com/termux/terminal/TerminalSession.java` — **upstream version** to compare with ours
- `termux-shared/src/main/java/com/termux/shared/termux/extrakeys/` — ExtraKeysView (681 lines), ExtraKeysInfo
- `termux-shared/src/main/java/com/termux/shared/termux/settings/properties/TermuxPropertyConstants.java` — contains default extra keys layout
- `app/src/main/java/com/termux/app/terminal/` — how Termux app integrates the terminal

### Termux Default Extra Keys Layout
From `TermuxPropertyConstants.java`:
```java
public static final String DEFAULT_IVALUE_EXTRA_KEYS =
  "[['ESC','/',{key: '-', popup: '|'},'HOME','UP','END','PGUP'], " +
   "['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]";
```
Two rows, 7 keys each. The `—` key has `|` as popup on long-press.

## Exact Next Steps

### Step 1: Switch from ChannelShell to ChannelExec (fixes locking + likely fixes scrolling)

This is the most important change. In `SshManager.kt`, replace `openShell()`:

**Current (broken)**:
```kotlin
val channel = sess.openChannel("shell") as ChannelShell
channel.setPtyType("xterm-256color", cols, rows, cols * 8, rows * 16)
channel.setPty(true)
val inputFromRemote = channel.inputStream
val outputToRemote = channel.outputStream
channel.connect(10_000)
shellChannel = channel
// Then sends tmux attach as text:
val attachCmd = "$tmuxPath attach -t '${sessionName}:${windowIndex}'\n"
outputToRemote.write(attachCmd.toByteArray())
```

**Target (matches Termux behavior)**:
```kotlin
val channel = sess.openChannel("exec") as ChannelExec
channel.setPtyType("xterm-256color", cols, rows, cols * 8, rows * 16)
channel.setPty(true)
channel.setCommand("$tmuxPath attach -t '${sessionName}:${windowIndex}'")
val inputFromRemote = channel.inputStream
val outputToRemote = channel.outputStream
channel.connect(10_000)
shellChannel = channel  // Note: shellChannel type needs to change to Channel
```

This runs `tmux attach` as the SSH command directly — exactly like `ssh -t host "tmux attach ..."` which is what the working Termux `handoff` script does.

**Also update**: The `shellChannel` field type from `ChannelShell?` to `Channel?`, and `resizeShell()` needs to call `channel.setPtySize()` which is available on ChannelExec too (you may need to cast or use reflection — check JSch API).

**IMPORTANT**: After this change, test that:
1. The Mac tmux session is NOT locked out
2. You can see terminal content
3. Scrolling works
4. Keyboard input works
5. Typing on Mac shows on phone and vice versa

### Step 2: Fix the extra keys toolbar

Replace our single-row `MobileToolbar.kt` with a 2-row layout matching Termux:
```
ESC  /  —  HOME  ↑  END  PGUP
TAB  CTRL  ALT  ←  ↓  →  PGDN
```

The `—` key should send `-` normally and `|` on long-press. CTRL and ALT should be toggles (like our current CTRL implementation).

You can either:
- Rewrite `MobileToolbar.kt` to have 2 rows with the correct keys
- Or port Termux's `ExtraKeysView.java` (681 lines) — but this is complex and may be overkill

### Step 3: Match font sizing

Termux auto-calculates font size. Our app hardcodes `setTextSize(28)` in TerminalScreen.kt. Either:
- Remove the hardcoded size and let the default work
- Or calculate based on screen density to get ~50-60 columns on a phone screen

### Step 4: Verify pinch-to-zoom

The TerminalView already has scale handling via `GestureAndScaleRecognizer`. Check if it works — our `viewClient.onScale()` returns the scale factor unchanged, which should be correct.

### Step 5: Handle resize when keyboard shows/hides

When the keyboard appears, the terminal should resize. Currently `imePadding()` handles the layout, but we also need to send the new terminal size to the SSH channel via `resizeShell()`. Check if `TerminalView.updateSize()` → `TerminalSession.updateSize()` is being called, and that it sends a window-change notification to the SSH channel.

## App Flow for Reference

1. First launch → WelcomeScreen → "Scan QR" button
2. ScanScreen → CameraX + ML Kit scans QR → JSON: `{"v":1,"ip":"...","user":"...","key":"...","tmux":"..."}`
3. Config saved to DataStore → navigate to TailscaleAuthScreen
4. TailscaleAuthScreen → starts embedded tsnet → first time: shows "Sign in to Tailscale" + browser auth; subsequent: auto-connects (~1-2s)
5. SessionsScreen: starts tsnet TCP proxy → SSH via `localhost:proxyPort` → `tmux list-sessions` → `tmux list-windows` → display cards
6. Tap a window → TerminalScreen: new SSH connection via proxy → exec channel → attach to tmux → render in TerminalView

## Dependencies (build.gradle.kts)
- Compose BOM 2024.12.01
- CameraX 1.4.1 + ML Kit barcode-scanning 17.3.0
- JSch 0.2.21 (com.github.mwiede:jsch)
- BouncyCastle 1.78.1 (bcprov-jdk18on)
- DataStore Preferences 1.1.1
- Security Crypto 1.1.0-alpha06
- Kotlin Coroutines 1.9.0
- gobridge.aar (gomobile-compiled Go tsnet bridge — tailscale.com v1.76.6)
- minSdk 26, compileSdk 36, targetSdk 35

### Building the Go bridge
```bash
cd android/gobridge
./build-aar.sh  # requires Go, Android NDK, gomobile
# Output: android/app/libs/gobridge.aar (~15MB)
```

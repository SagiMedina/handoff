#!/bin/bash
# Build the Handoff Android app — checks prereqs and builds everything.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Handoff Android Build"
echo "  ────────────────────────"
echo ""

# ─── Detect Android SDK ──────────────────────────────────────────
if [ -z "${ANDROID_HOME:-}" ]; then
    for dir in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/android-sdk; do
        if [ -d "$dir" ]; then
            export ANDROID_HOME="$dir"
            break
        fi
    done
fi
if [ -z "${ANDROID_HOME:-}" ]; then
    echo "ERROR: Android SDK not found."
    echo "  Install Android Studio: brew install --cask android-studio"
    echo "  Then open it once to complete the SDK setup wizard."
    exit 1
fi

# ─── Generate local.properties if missing ─────────────────────────
if [ ! -f local.properties ]; then
    echo "  Generating local.properties..."
    echo "sdk.dir=$ANDROID_HOME" > local.properties
fi

# ─── Select JDK 17 if available ───────────────────────────────────
if command -v /usr/libexec/java_home &>/dev/null; then
    if /usr/libexec/java_home -v 17 &>/dev/null; then
        export JAVA_HOME=$(/usr/libexec/java_home -v 17)
    fi
fi

# ─── Build Go bridge if needed ────────────────────────────────────
if [ ! -f app/libs/gobridge.aar ]; then
    echo "  gobridge.aar not found — building Go bridge..."
    (cd gobridge && ./build-aar.sh)
    echo ""
fi

# ─── Build APK ────────────────────────────────────────────────────
echo "==> Building debug APK..."
./gradlew assembleDebug

APK="app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "==> Build complete: $APK"
ls -lh "$APK"

# ─── Install if device connected ─────────────────────────────────
ADB="$ANDROID_HOME/platform-tools/adb"
if [ -x "$ADB" ]; then
    DEVICES=$("$ADB" devices 2>/dev/null | grep -w device | head -1 || true)
    if [ -n "$DEVICES" ]; then
        echo ""
        echo "==> Installing on connected device..."
        "$ADB" install -r "$APK"
    else
        echo ""
        echo "  No device connected. To install later:"
        echo "    $ADB install $APK"
    fi
else
    echo ""
    echo "  adb not found. To install on a device:"
    echo "    sdkmanager --install 'platform-tools'"
    echo "    \$ANDROID_HOME/platform-tools/adb install $APK"
fi

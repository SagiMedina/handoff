#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking prerequisites..."

# 1. Go
if ! command -v go &>/dev/null; then
    echo "ERROR: Go is not installed. Install from https://go.dev/dl/ or: brew install go"
    exit 1
fi

# 2. Java — required for gomobile bind (jar/javac)
if ! command -v java &>/dev/null; then
    echo "ERROR: Java is not installed."
    echo "  Install JDK 17: brew install --cask temurin@17"
    exit 1
fi

JAVA_VER=$(java -version 2>&1 | head -1 | sed 's/.*"\([0-9]*\).*/\1/')
if [[ "$JAVA_VER" -gt 21 ]]; then
    # Try to find JDK 17 automatically
    if /usr/libexec/java_home -v 17 &>/dev/null; then
        export JAVA_HOME=$(/usr/libexec/java_home -v 17)
        echo "  JAVA_HOME=$JAVA_HOME (auto-selected JDK 17; JDK $JAVA_VER is too new)"
    else
        echo "ERROR: JDK $JAVA_VER is too new for Android tooling (max 21)."
        echo "  Install JDK 17: brew install --cask temurin@17"
        exit 1
    fi
fi

# 3. Android SDK
if [ -z "${ANDROID_HOME:-}" ]; then
    # Try common locations
    for dir in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/android-sdk; do
        if [ -d "$dir" ]; then
            export ANDROID_HOME="$dir"
            break
        fi
    done
    if [ -z "${ANDROID_HOME:-}" ]; then
        echo "ERROR: ANDROID_HOME not set and Android SDK not found."
        echo "  Install Android Studio: brew install --cask android-studio"
        echo "  Then open it once to complete the SDK setup wizard."
        exit 1
    fi
fi
echo "  ANDROID_HOME=$ANDROID_HOME"

# 4. Android NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    NDK_DIR="$ANDROID_HOME/ndk"
    if [ -d "$NDK_DIR" ]; then
        # Use the latest NDK version available
        ANDROID_NDK_HOME="$NDK_DIR/$(ls "$NDK_DIR" | sort -V | tail -1)"
        export ANDROID_NDK_HOME
    fi
fi
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: Android NDK not found."
    echo "  Install via: sdkmanager --sdk_root=\"\$ANDROID_HOME\" --install 'ndk;27.0.12077973'"
    exit 1
fi
echo "  ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

# 5. Android SDK platform (API 26 required by gomobile)
if [ ! -d "$ANDROID_HOME/platforms/android-26" ]; then
    echo "  Android SDK platform 26 not found — installing..."
    if command -v sdkmanager &>/dev/null; then
        sdkmanager --sdk_root="$ANDROID_HOME" --install 'platforms;android-26' || {
            echo "ERROR: Failed to install SDK platform 26."
            echo "  Install manually: sdkmanager --sdk_root=\"\$ANDROID_HOME\" --install 'platforms;android-26'"
            exit 1
        }
    else
        echo "ERROR: Android SDK platform 26 not found and sdkmanager not available."
        echo "  Install command-line tools: brew install --cask android-commandlinetools"
        echo "  Then: sdkmanager --sdk_root=\"\$ANDROID_HOME\" --install 'platforms;android-26'"
        exit 1
    fi
fi

echo "==> Installing gomobile..."
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

# Ensure GOPATH/bin is in PATH
export PATH="$(go env GOPATH)/bin:$PATH"

echo "==> Initializing gomobile..."
gomobile init

echo "==> Building gobridge.aar..."
mkdir -p ../app/libs

# Force local toolchain to avoid "toolchain not available" errors
# when go.mod requires a version matching the installed Go.
export GOTOOLCHAIN="go$(go env GOVERSION | sed 's/^go//')"

gomobile bind \
    -v \
    -target=android/arm64 \
    -androidapi 26 \
    -o ../app/libs/gobridge.aar \
    .

echo "==> Done! Output: ../app/libs/gobridge.aar"
ls -lh ../app/libs/gobridge.aar

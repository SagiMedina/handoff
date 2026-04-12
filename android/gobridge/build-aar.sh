#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking prerequisites..."

if ! command -v go &>/dev/null; then
    echo "ERROR: Go is not installed. Install from https://go.dev/dl/"
    exit 1
fi

if [ -z "${ANDROID_HOME:-}" ]; then
    # Try common locations
    for dir in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/android-sdk; do
        if [ -d "$dir" ]; then
            export ANDROID_HOME="$dir"
            break
        fi
    done
    if [ -z "${ANDROID_HOME:-}" ]; then
        echo "ERROR: ANDROID_HOME not set and Android SDK not found"
        exit 1
    fi
fi
echo "  ANDROID_HOME=$ANDROID_HOME"

# Find NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    NDK_DIR="$ANDROID_HOME/ndk"
    if [ -d "$NDK_DIR" ]; then
        # Use the latest NDK version available
        ANDROID_NDK_HOME="$NDK_DIR/$(ls "$NDK_DIR" | sort -V | tail -1)"
        export ANDROID_NDK_HOME
    fi
fi
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ERROR: Android NDK not found. Install via: sdkmanager --install 'ndk;27.0.12077973'"
    exit 1
fi
echo "  ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

echo "==> Installing gomobile..."
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

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

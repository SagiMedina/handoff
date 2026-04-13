#!/bin/bash
# Build the Gobridge.xcframework for iOS from the shared Go bridge code.
# Uses the same bridge.go as Android — compiled via gomobile for iOS.
#
# Requires:
#   - Go (https://go.dev/dl/)
#   - Xcode (for iOS SDK)
#
# Usage:
#   ./scripts/build-gobridge.sh
#
# Output:
#   ios/Handoff/Frameworks/Gobridge.xcframework

set -euo pipefail

cd "$(dirname "$0")/../../android/gobridge"

echo "==> Checking prerequisites..."

if ! command -v go &>/dev/null; then
    echo "ERROR: Go is not installed. Install from https://go.dev/dl/"
    exit 1
fi
echo "  Go: $(go version)"

echo "==> Installing gomobile..."
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

# Ensure gomobile is in PATH
export PATH="$HOME/go/bin:$PATH"

echo "==> Initializing gomobile..."
gomobile init

echo "==> Building Gobridge.xcframework..."
OUTDIR="$(dirname "$0")/../Handoff/Frameworks"
mkdir -p "$OUTDIR"

# Force local toolchain to match go.mod
export GOTOOLCHAIN="go$(go env GOVERSION | sed 's/^go//')"

gomobile bind \
    -v \
    -target=ios/arm64,iossimulator/arm64 \
    -o "$OUTDIR/Gobridge.xcframework" \
    .

echo "==> Done! Output: $OUTDIR/Gobridge.xcframework"
ls -lh "$OUTDIR/Gobridge.xcframework"

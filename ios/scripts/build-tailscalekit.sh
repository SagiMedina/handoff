#!/bin/bash
# Build TailscaleKit.xcframework for iOS from Tailscale's official libtailscale repo.
# Replaces the earlier raw gomobile bind of tsnet — TailscaleKit is the supported
# iOS embedding for Tailscale's userspace networking.
#
# Requires:
#   - Go (https://go.dev/dl/) — for libtailscale's static archive build
#   - Xcode 16.1+ — for the Swift framework wrapper
#
# Usage:
#   ./scripts/build-tailscalekit.sh
#
# Output:
#   ios/Handoff/Frameworks/TailscaleKit.xcframework

set -euo pipefail

REPO_URL="https://github.com/tailscale/libtailscale"
WORK_DIR="${WORK_DIR:-/tmp/libtailscale-build}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Handoff/Frameworks"

echo "==> Checking prerequisites..."
command -v go &>/dev/null || { echo "ERROR: Go not installed (https://go.dev/dl/)"; exit 1; }
command -v xcodebuild &>/dev/null || { echo "ERROR: Xcode not installed"; exit 1; }
echo "  Go: $(go version)"
echo "  Xcode: $(xcodebuild -version | head -1)"

echo "==> Cloning/updating libtailscale..."
if [ -d "$WORK_DIR" ]; then
    git -C "$WORK_DIR" fetch --depth 1 origin main
    git -C "$WORK_DIR" reset --hard origin/main
else
    git clone --depth 1 "$REPO_URL" "$WORK_DIR"
fi

echo "==> Building TailscaleKit.xcframework (device + simulator)..."
cd "$WORK_DIR/swift"
make ios-fat

SRC="$WORK_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
[ -d "$SRC" ] || { echo "ERROR: build did not produce $SRC"; exit 1; }

echo "==> Installing into $OUT_DIR..."
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/TailscaleKit.xcframework"
cp -R "$SRC" "$OUT_DIR/"

echo "==> Done!"
du -sh "$OUT_DIR/TailscaleKit.xcframework"

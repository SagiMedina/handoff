#!/bin/bash
# Build TailscaleKit.xcframework for iOS from Tailscale's official libtailscale repo.
# Replaces the earlier raw gomobile bind of tsnet — TailscaleKit is the supported
# iOS embedding for Tailscale's userspace networking.
#
# The libtailscale commit is pinned (LIBTAILSCALE_REF below) so the produced
# framework is reproducible across machines and CI runs. To upgrade:
#   1. Test the new commit locally
#   2. Update LIBTAILSCALE_REF in this script
#   3. Re-run and re-test
#
# Requires:
#   - Go (https://go.dev/dl/) — for libtailscale's static archive build
#   - Xcode 16.1+ — for the Swift framework wrapper
#
# Usage:
#   ./scripts/build-tailscalekit.sh                   # build at pinned ref
#   LIBTAILSCALE_REF=main ./scripts/build-tailscalekit.sh   # build at upstream main (not pinned, for testing)
#
# Output:
#   ios/Handoff/Frameworks/TailscaleKit.xcframework

set -euo pipefail

REPO_URL="https://github.com/tailscale/libtailscale"
LIBTAILSCALE_REF="${LIBTAILSCALE_REF:-5e89501def80a6579ca5d0f9a02f336be62b8f2e}"
WORK_DIR="${WORK_DIR:-/tmp/libtailscale-build}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Handoff/Frameworks"

echo "==> Checking prerequisites..."
command -v go &>/dev/null || { echo "ERROR: Go not installed (https://go.dev/dl/)"; exit 1; }
command -v xcodebuild &>/dev/null || { echo "ERROR: Xcode not installed"; exit 1; }
echo "  Go: $(go version)"
echo "  Xcode: $(xcodebuild -version | head -1)"
echo "  libtailscale ref: $LIBTAILSCALE_REF"

echo "==> Cloning/updating libtailscale at $LIBTAILSCALE_REF..."
if [ ! -d "$WORK_DIR/.git" ]; then
    git clone "$REPO_URL" "$WORK_DIR"
fi
git -C "$WORK_DIR" fetch origin
git -C "$WORK_DIR" checkout "$LIBTAILSCALE_REF"

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
echo "  built from libtailscale @ $LIBTAILSCALE_REF"

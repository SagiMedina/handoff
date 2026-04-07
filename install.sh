#!/usr/bin/env bash
# Handoff — Manual installer for macOS
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"

echo "Installing Handoff to $PREFIX..."

mkdir -p "$PREFIX/bin"
mkdir -p "$PREFIX/lib/handoff"

cp bin/handoff "$PREFIX/bin/handoff"
chmod +x "$PREFIX/bin/handoff"

cp lib/handoff-common.sh "$PREFIX/lib/handoff/handoff-common.sh"

echo "✓ Installed. Run 'handoff setup' to get started."

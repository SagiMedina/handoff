#!/bin/bash
# Generate the Xcode project from project.yml using XcodeGen.
# Requires: brew install xcodegen
set -euo pipefail
cd "$(dirname "$0")/../Handoff"
xcodegen generate
echo "Xcode project generated at ios/Handoff/Handoff.xcodeproj"
echo "Open with: open Handoff.xcodeproj"

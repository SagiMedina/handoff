#!/bin/bash
# Generate the Xcode project from project.yml using XcodeGen.
#
# Requires:
#   brew install xcodegen
#
# Environment variables:
#   DEVELOPMENT_TEAM   (required for device builds) — your Apple Developer Team ID,
#                      visible at https://developer.apple.com/account (Membership tab).
#                      For a free personal team, look it up in Xcode:
#                      Settings → Accounts → [your Apple ID] → Manage Certificates,
#                      or from a signed cert:
#                        security find-certificate -c "Apple Development" -p \
#                          | openssl x509 -noout -subject | grep -oE 'OU=[A-Z0-9]+'
#
#   BUNDLE_ID_PREFIX   (required) — reverse-DNS prefix for your app bundle ID.
#                      Example: dev.yourname.handoff
#
# Usage:
#   DEVELOPMENT_TEAM=ABC123XYZ9 BUNDLE_ID_PREFIX=dev.yourname.handoff ./scripts/generate.sh
#
# For simulator-only builds, DEVELOPMENT_TEAM can be empty.

set -euo pipefail

: "${BUNDLE_ID_PREFIX:?BUNDLE_ID_PREFIX must be set (e.g. dev.yourname.handoff). See ios/README.md}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

cd "$(dirname "$0")/../Handoff"
xcodegen generate
echo "Xcode project generated at ios/Handoff/Handoff.xcodeproj"
echo "Open with: open Handoff.xcodeproj"

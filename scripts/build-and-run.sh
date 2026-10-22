#!/bin/bash
# Builds Rounds with xcodebuild and launches it. Usage: scripts/build-and-run.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
xcodebuild \
  -project Rounds.xcodeproj \
  -scheme Rounds \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
open "build/Build/Products/$CONFIG/Rounds.app"

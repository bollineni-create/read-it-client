#!/bin/bash
# Runs the RoundsCore unit tests through Xcode (and through SwiftPM as a cross-check).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Rounds.xcodeproj -scheme Rounds -destination 'platform=macOS' -derivedDataPath build test
swift test --package-path RoundsCore

#!/bin/bash
# Turns off auto-update. Leaves /Applications/Rounds.app and your library in place.
set -euo pipefail
LABEL="com.naren.rounds.auto-update"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/Rounds Auto-Update"
echo "Auto-update is off."

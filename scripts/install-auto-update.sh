#!/bin/bash
# Installs a launch agent that runs scripts/auto-update.sh at login and every 5 minutes, so
# /Applications/Rounds.app rebuilds itself whenever main changes on GitHub. Runs one update right away.
# Undo with scripts/uninstall-auto-update.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
LABEL="com.naren.rounds.auto-update"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "$ROOT" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
    echo "This clone is in $ROOT."
    echo "macOS blocks background jobs from reading Desktop, Documents and Downloads, so updates would fail."
    echo "Move the clone somewhere else (for example ~/Developer/read-it-client) and run this again."
    exit 1 ;;
esac

if ! command -v xcodebuild >/dev/null || ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild isn't working. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

chmod +x scripts/auto-update.sh
mkdir -p "$(dirname "$PLIST")"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$ROOT/scripts/auto-update.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Auto-update is on. Rounds in /Applications now follows main on GitHub (checked every 5 minutes)."
echo "The first build is running now. Progress: ~/Library/Logs/Rounds-auto-update.log"

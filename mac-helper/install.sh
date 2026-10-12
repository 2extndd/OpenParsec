#!/usr/bin/env bash
# Build ParsecLowDisplay and run it at login (LaunchAgent, restarted if it
# exits). Re-run after pulling changes; `install.sh --uninstall` removes it.
set -euo pipefail
cd "$(dirname "$0")"
LABEL=com.extnddos.openparsec.low-display
BIN="$HOME/Library/Application Support/OpenParsec/ParsecLowDisplay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true # its virtual display goes with it
if [[ "${1:-}" == "--uninstall" ]]; then rm -f "$PLIST" "$BIN"; echo "uninstalled"; exit 0; fi

mkdir -p "$(dirname "$BIN")" "$HOME/Library/LaunchAgents"
xcrun clang -O2 -fobjc-arc -framework Cocoa -framework Carbon ParsecLowDisplay.m -o "$BIN.new"
"$BIN.new" --self-test
mv "$BIN.new" "$BIN"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/ParsecLowDisplay.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
sleep 1
launchctl print "gui/$UID/$LABEL" | grep -E "state|pid" | head -2
echo "installed; log: ~/Library/Logs/ParsecLowDisplay.log"

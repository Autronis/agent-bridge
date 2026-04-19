#!/usr/bin/env bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.autronis.plan-avond.plist"
[[ -f "$PLIST" ]] && launchctl unload "$PLIST" && rm "$PLIST"
echo "Uninstalled."

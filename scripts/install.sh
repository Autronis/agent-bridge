#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH="$HOME/.config/autronis/agent-bridge.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config niet gevonden. Kopieer config/settings.example.json naar $CONFIG_PATH en pas aan."
  exit 1
fi

USER_NAME=$(python3 -c "import json,os,sys; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['user'])")
ATLAS_TIME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['atlas_start_time'])")
AUTRO_TIME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['autro_start_time'])")

if [[ "$USER_NAME" == "sem" ]]; then TIME="$ATLAS_TIME"; else TIME="$AUTRO_TIME"; fi
HOUR=$(echo "$TIME" | cut -d: -f1)
MIN=$(echo "$TIME" | cut -d: -f2)

mkdir -p "$PROJECT_DIR/logs"
PLIST_OUT="$HOME/Library/LaunchAgents/com.autronis.plan-avond.plist"

sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MIN|g" \
    "$PROJECT_DIR/launchd/com.autronis.plan-avond.plist.template" > "$PLIST_OUT"

launchctl unload "$PLIST_OUT" 2>/dev/null || true
launchctl load -w "$PLIST_OUT"
echo "Installed for user=$USER_NAME at $TIME. Check: launchctl list | grep plan-avond"

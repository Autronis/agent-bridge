#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH="$HOME/.config/autronis/agent-bridge.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config niet gevonden. Kopieer config/settings.example.json naar $CONFIG_PATH en pas aan."
  exit 1
fi

read_cfg() {
  CONFIG_PATH="$CONFIG_PATH" python3 -c '
import json, os, sys
with open(os.environ["CONFIG_PATH"]) as f:
    print(json.load(f)[sys.argv[1]])
' "$1"
}

USER_NAME=$(read_cfg user)
ATLAS_TIME=$(read_cfg atlas_start_time)
AUTRO_TIME=$(read_cfg autro_start_time)

case "$USER_NAME" in
  sem) TIME="$ATLAS_TIME" ;;
  syb) TIME="$AUTRO_TIME" ;;
  *) echo "Fout: 'user' in $CONFIG_PATH moet 'sem' of 'syb' zijn (kreeg: '$USER_NAME')" >&2; exit 1 ;;
esac
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

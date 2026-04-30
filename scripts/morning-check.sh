#!/usr/bin/env bash
# morning-check.sh
# Draait om 07:00 via launchd. Checkt of de bridge vannacht agenda-blokken
# heeft gemaakt voor vandaag. Zo niet: trigger Haiku fallback + Discord alert.
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "morning-check: config niet gevonden op $CONFIG_PATH" >&2
  exit 1
fi

read_cfg() {
  CONFIG_PATH="$CONFIG_PATH" python3 -c '
import json, os, sys
with open(os.environ["CONFIG_PATH"]) as f:
    cfg = json.load(f)
key = sys.argv[1]
if key not in cfg:
    sys.exit("missing key: " + key)
val = cfg[key]
if isinstance(val, str):
    print(os.path.expanduser(val))
else:
    print(json.dumps(val))
' "$1"
}

USER_NAME=$(read_cfg user)
DASHBOARD_URL=$(read_cfg dashboard_url)
API_KEY_FILE=$(read_cfg dashboard_api_key_file)
DISCORD_BOT=$(read_cfg discord_bot_script)

API_KEY=$(API_KEY_FILE="$API_KEY_FILE" python3 -c '
import json, os
with open(os.path.expanduser(os.environ["API_KEY_FILE"])) as f:
    print(json.load(f)["api_key"])
')

TODAY=$(date +%Y-%m-%d)

RESPONSE=$(curl -s -H "Authorization: Bearer $API_KEY" \
  "${DASHBOARD_URL}/api/agenda?van=${TODAY}&tot=${TODAY}")

BRIDGE_COUNT=$(RESPONSE="$RESPONSE" python3 <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["RESPONSE"])
    items = data.get("items", [])
    count = sum(1 for i in items if i.get("gemaaktDoor") == "bridge")
    print(count)
except:
    print(0)
PY
)

if [[ "$BRIDGE_COUNT" -gt 0 ]]; then
  echo "morning-check: ${BRIDGE_COUNT} bridge-blokken gevonden voor ${TODAY} — OK"
  exit 0
fi

echo "morning-check: GEEN bridge-blokken voor ${TODAY} — trigger fallback"

FALLBACK_RESULT=$(curl -s -w "\nHTTP:%{http_code}" \
  -X POST "${DASHBOARD_URL}/api/agenda/ai-plan?force=true" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"datum\": \"${TODAY}\", \"eigenaar\": \"${USER_NAME}\"}")

HTTP_CODE=$(echo "$FALLBACK_RESULT" | grep "^HTTP:" | cut -d: -f2)

if [[ "$HTTP_CODE" == 2* ]]; then
  "$DISCORD_BOT" send "ALERT: Bridge heeft vannacht geen plan gemaakt voor ${TODAY}. Haiku fallback is getriggerd en heeft blokken aangemaakt." 2>/dev/null || true
else
  "$DISCORD_BOT" send "ALERT: Bridge heeft vannacht geen plan gemaakt voor ${TODAY}. Haiku fallback is ook GEFAALD (HTTP ${HTTP_CODE}). Handmatig plannen nodig." 2>/dev/null || true
fi

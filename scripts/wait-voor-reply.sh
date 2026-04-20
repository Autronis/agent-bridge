#!/usr/bin/env bash
# wait-voor-reply.sh
# Polt Discord #claude-handoffs voor een BRIDGE-REPLY-<USER_UPPER> bericht
# dat na BRIDGE-VOORSTEL-<USER_UPPER> is gepost. Print de body van het reply
# naar stdout (alles tussen het marker en de volgende BRIDGE-*-regel) bij
# succes. Leeg stdout bij timeout — caller moet dat afvangen en gewoon
# originele plan committen.
#
# Usage:
#   scripts/wait-voor-reply.sh [max-wait-seconds]
#
# Default timeout: 600s (10 min).
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "wait-voor-reply: config niet gevonden op $CONFIG_PATH" >&2
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
DISCORD_BOT=$(read_cfg discord_bot_script)

USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
MARKER="BRIDGE-REPLY-${USER_UPPER}"

MAX_WAIT="${1:-600}"   # default 10 minuten
POLL_INTERVAL=30

ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  # Haal laatste 30 berichten op. discord-bot.sh read is chronologisch oud→nieuw,
  # dus de nieuwste reply zit achteraan.
  MSGS=$("$DISCORD_BOT" read 30 2>/dev/null || echo "")

  REPLY_BODY=$(MSGS="$MSGS" MARKER="$MARKER" python3 <<'PY'
import os, re, sys
msgs = os.environ["MSGS"]
marker = os.environ["MARKER"]
idx = msgs.rfind(marker)
if idx == -1:
    print("", end="")
    sys.exit(0)
# Pak alles na marker-regel tot de volgende BRIDGE- header of max 2000 chars.
tail = msgs[idx + len(marker):]
m = re.search(r"\nBRIDGE-", tail)
end = m.start() if m else min(len(tail), 2000)
body = tail[:end].strip()
print(body)
PY
  )

  if [[ -n "$REPLY_BODY" ]]; then
    printf '%s\n' "$REPLY_BODY"
    exit 0
  fi

  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Timeout — print niks naar stdout, caller ziet lege string.
echo "wait-voor-reply: timeout na ${MAX_WAIT}s zonder reply" >&2
exit 0

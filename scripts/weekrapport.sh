#!/usr/bin/env bash
# weekrapport.sh
# Genereert een AI-samenvatting van de afgelopen werkweek via het dashboard
# screen-time endpoint en post die naar Discord (#weekrapport-sem of
# #weekrapport-syb, afhankelijk van config).
#
# Flow:
#   1. Load config, bepaal user + Discord bot script.
#   2. Bereken maandag van de lopende week (weekrapport draait zondag 19:00;
#      dan is vandaag = zondag, maandag = 6 dagen terug).
#   3. POST /api/screen-time/samenvatting/periode {datum, type:"week"} →
#      dashboard genereert + persisteert rapport, returnt JSON.
#   4. Build Discord message (header + totalen + top project + kort + detail).
#   5. Chunk bij Discord's 2000-char limiet; post via discord-bot.sh.
#   6. Bij fout: FOUT-bericht naar handoffs, exit 1.
#
# Usage:
#   scripts/weekrapport.sh
#
# Exit codes:
#   0 — rapport gegenereerd en gepost
#   1 — config/API fout
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "weekrapport: config niet gevonden op $CONFIG_PATH" >&2
  exit 1
fi

# Veilige config-reader — geen string-interpolatie in Python source.
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
ROLE=$(read_cfg role_name)
DASHBOARD_URL=$(read_cfg dashboard_url)
API_KEY_FILE=$(read_cfg dashboard_api_key_file)
DISCORD_BOT_RAW=$(read_cfg discord_bot_script)

# Expand ~ in discord bot script path.
DISCORD_BOT="${DISCORD_BOT_RAW/#\~/$HOME}"

if [[ ! -x "$DISCORD_BOT" ]]; then
  echo "weekrapport: discord bot script niet uitvoerbaar op $DISCORD_BOT" >&2
  exit 1
fi

if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "weekrapport: dashboard api key file niet gevonden: $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(API_KEY_FILE="$API_KEY_FILE" python3 -c '
import json, os
with open(os.environ["API_KEY_FILE"]) as f:
    cfg = json.load(f)
if "api_key" not in cfg:
    raise SystemExit("api_key ontbreekt in api key file")
print(cfg["api_key"])
')

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG="$LOG_DIR/weekrapport_$TIMESTAMP.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# Bepaal channel o.b.v. user.
case "$USER_NAME" in
  sem) CHANNEL="weekrapport-sem" ;;
  syb) CHANNEL="weekrapport-syb" ;;
  *)
    log "Fout: user in config moet 'sem' of 'syb' zijn (kreeg: '$USER_NAME')"
    exit 1
    ;;
esac

# Bereken maandag van de lopende week + zondag (= maandag + 6 dagen).
# Override voor testing: WEEKRAPPORT_DATUM=YYYY-MM-DD (elke dag in de gewenste week).
DATES=$(WEEKRAPPORT_DATUM="${WEEKRAPPORT_DATUM:-}" python3 <<'PY'
import os
from datetime import date, timedelta
override = os.environ.get("WEEKRAPPORT_DATUM", "").strip()
if override:
    vandaag = date.fromisoformat(override)
else:
    vandaag = date.today()
# (weekday() - 0) % 7 = aantal dagen terug naar meest recente maandag.
# Zondag (weekday=6) → 6 dagen terug = maandag van de week die we net afsluiten.
# Maandag (weekday=0) → 0 dagen = vandaag (begin nieuwe week).
dagen_terug = (vandaag.weekday() - 0) % 7
maandag = vandaag - timedelta(days=dagen_terug)
zondag = maandag + timedelta(days=6)
print(maandag.isoformat())
print(zondag.isoformat())
PY
)
MAANDAG=$(echo "$DATES" | sed -n '1p')
ZONDAG=$(echo "$DATES" | sed -n '2p')

log "Start weekrapport voor user=$USER_NAME role=$ROLE (week $MAANDAG..$ZONDAG)"

# POST naar dashboard endpoint.
RESP_FILE=$(mktemp /tmp/weekrapport-resp-XXXXXX)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "$DASHBOARD_URL/api/screen-time/samenvatting/periode" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"datum\":\"$MAANDAG\",\"type\":\"week\"}" || echo "000")

log "POST /api/screen-time/samenvatting/periode → HTTP $HTTP_CODE"

if [[ "$HTTP_CODE" != "200" ]]; then
  RESP_PREVIEW=$(head -c 400 "$RESP_FILE" || true)
  log "API fout: $RESP_PREVIEW"
  USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
  "$DISCORD_BOT" send "WEEKRAPPORT-$USER_UPPER FOUT: HTTP $HTTP_CODE bij /api/screen-time/samenvatting/periode (week $MAANDAG). Log: $LOG" 2>&1 | tee -a "$LOG" || true
  exit 1
fi

# Build Discord message uit response JSON.
MESSAGE=$(RESP_FILE="$RESP_FILE" USER_NAME="$USER_NAME" ROLE="$ROLE" MAANDAG="$MAANDAG" ZONDAG="$ZONDAG" python3 <<'PY'
import json, os, sys

with open(os.environ["RESP_FILE"]) as f:
    data = json.load(f)

samenvatting = data.get("samenvatting") or {}
if not samenvatting:
    sys.exit("response bevat geen 'samenvatting' veld: " + json.dumps(data)[:300])

user_upper = os.environ["USER_NAME"].upper()
role = os.environ["ROLE"]
maandag = os.environ["MAANDAG"]
zondag = os.environ["ZONDAG"]

totaal_s = int(samenvatting.get("totaalSeconden") or 0)
uren = totaal_s // 3600
minuten = (totaal_s % 3600) // 60

productief_pct = samenvatting.get("productiefPercentage")
top_project = samenvatting.get("topProject") or "(geen project gedetecteerd)"
kort = samenvatting.get("samenvattingKort") or ""
detail = samenvatting.get("samenvattingDetail")

# Detail kan een string (markdown) of een lijst van strings (bullets) zijn —
# normaliseer naar één string met newlines.
if isinstance(detail, list):
    detail_str = "\n".join(str(x) for x in detail)
elif isinstance(detail, str):
    detail_str = detail
else:
    detail_str = ""

lines = [
    f"WEEKRAPPORT-{user_upper} {role} voor week {maandag} — {zondag}",
    "",
    f"Totaal actief: {uren}u {minuten}m",
]
if productief_pct is not None:
    lines.append(f"Productief: {productief_pct}%")
lines.append(f"Top project: {top_project}")
lines.append("")
if kort:
    lines.append("Kort:")
    lines.append(kort)
    lines.append("")
if detail_str:
    lines.append("Detail:")
    lines.append(detail_str)

sys.stdout.write("\n".join(lines))
PY
)

if [[ -z "$MESSAGE" ]]; then
  log "Fout: lege message gebouwd"
  USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
  "$DISCORD_BOT" send "WEEKRAPPORT-$USER_UPPER FOUT: kon message niet bouwen uit response. Log: $LOG" 2>&1 | tee -a "$LOG" || true
  exit 1
fi

CHARS=$(printf '%s' "$MESSAGE" | wc -c | tr -d ' ')
log "Message gebouwd ($CHARS chars), chunk-split naar Discord 2000-limiet"

# Chunk in stukken van max 1900 chars (ruimte voor @mentions die
# discord-bot.sh automatisch toevoegt via get_mention_suffix).
# Split op double-newline / newline grenzen indien mogelijk zodat paragrafen
# intact blijven. Output: chunks separator = \x1E (RS).
MSG_FILE=$(mktemp /tmp/weekrapport-msg-XXXXXX)
CHUNKS_FILE=$(mktemp /tmp/weekrapport-chunks-XXXXXX)
trap 'rm -f "$RESP_FILE" "$MSG_FILE" "$CHUNKS_FILE"' EXIT

printf '%s' "$MESSAGE" > "$MSG_FILE"

# Lees via MSG_FILE env-var (pipe+heredoc conflicteren op stdin, dus via file).
MSG_FILE="$MSG_FILE" python3 <<'PY' > "$CHUNKS_FILE"
import os, sys

MAX = 1900
with open(os.environ["MSG_FILE"]) as f:
    msg = f.read()

def split_on_boundaries(text, limit):
    chunks = []
    while len(text) > limit:
        # zoek laatste double-newline binnen limit; anders laatste newline;
        # anders laatste spatie; anders hard-cut op limit.
        cut = text.rfind("\n\n", 0, limit)
        if cut < 200:
            cut = text.rfind("\n", 0, limit)
        if cut < 200:
            cut = text.rfind(" ", 0, limit)
        if cut < 200:
            cut = limit
        chunks.append(text[:cut].rstrip())
        text = text[cut:].lstrip()
    if text:
        chunks.append(text)
    return chunks

chunks = split_on_boundaries(msg, MAX)
total = len(chunks)

for i, c in enumerate(chunks, 1):
    if total > 1:
        header = f"[{i}/{total}]\n"
        # Als de header erbij past onder MAX, prepend 'm; anders laat 'm weg.
        if len(header) + len(c) <= 2000:
            c = header + c
    # Gebruik \x1E als record-separator (onwaarschijnlijk in tekst).
    sys.stdout.write(c)
    sys.stdout.write("\x1e")
PY

# Post elke chunk.
POST_OK=0
POST_FAIL=0
# Parseer chunks met \x1E als separator — veilig, komt niet voor in plain text.
while IFS= read -r -d $'\x1e' CHUNK; do
  if [[ -z "$CHUNK" ]]; then continue; fi
  CHUNK_LEN=$(printf '%s' "$CHUNK" | wc -c | tr -d ' ')
  log "Post chunk ($CHUNK_LEN chars) naar #$CHANNEL..."
  if "$DISCORD_BOT" post "$CHANNEL" "$CHUNK" 2>&1 | tee -a "$LOG" | grep -q "Verzonden naar #$CHANNEL"; then
    POST_OK=$((POST_OK + 1))
  else
    POST_FAIL=$((POST_FAIL + 1))
  fi
done < "$CHUNKS_FILE"

log "Posts: $POST_OK succes, $POST_FAIL fout"

if [[ "$POST_FAIL" -gt 0 ]]; then
  USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
  "$DISCORD_BOT" send "WEEKRAPPORT-$USER_UPPER FOUT: $POST_FAIL van $((POST_OK + POST_FAIL)) chunks faalden bij post naar #$CHANNEL. Log: $LOG" 2>&1 | tee -a "$LOG" || true
  exit 1
fi

log "Klaar — weekrapport gepost naar #$CHANNEL"

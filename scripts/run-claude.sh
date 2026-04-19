#!/usr/bin/env bash
# run-claude.sh
# Combineert het plan-avond system prompt + context JSON en roept `claude -p`
# headless aan. Valideert dat de response geldig JSON is met {datum, blokken}.
#
# Usage:
#   scripts/run-claude.sh                    # zonder partner voorstel
#   scripts/run-claude.sh "<partner tekst>"  # voegt partner_voorstel toe aan context
#
# Exit codes:
#   0 — valid JSON naar stdout
#   1 — config/template fout of invalid JSON (raw dump naar stderr)
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "run-claude: config niet gevonden op $CONFIG_PATH" >&2
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
    print(val)
else:
    print(json.dumps(val))
' "$1"
}

USER_NAME=$(read_cfg user)
ROLE=$(read_cfg role_name)
PARTNER=$(read_cfg partner_role_name)
CLAUDE_BIN=$(read_cfg claude_binary)

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "run-claude: claude binary niet uitvoerbaar op $CLAUDE_BIN" >&2
  exit 1
fi

NOW=$(date '+%Y-%m-%d %H:%M')
if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
  TOMORROW=$(date -v+1d +%Y-%m-%d)   # BSD / macOS
else
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)   # GNU / Linux / git-bash / MSYS
fi

case "$USER_NAME" in
  sem) FRIENDLY="Sem" ;;
  syb) FRIENDLY="Syb" ;;
  *) echo "run-claude: user moet sem of syb zijn (was: $USER_NAME)" >&2; exit 1 ;;
esac

PROMPT_FILE="$PROJECT_DIR/prompts/plan-avond.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "run-claude: prompt template niet gevonden: $PROMPT_FILE" >&2
  exit 1
fi

# Render system prompt. Python ipv sed omdat config-values speciale tekens kunnen
# bevatten (|, \, &) die sed breken. Placeholders komen via env-vars, niet source.
SYSTEM_PROMPT=$(
  PROMPT_FILE="$PROMPT_FILE" \
  ROLE="$ROLE" \
  PARTNER_ROLE="$PARTNER" \
  USER_NAME="$USER_NAME" \
  USER_FRIENDLY_NAME="$FRIENDLY" \
  HUIDIG_TIJDSTIP="$NOW" \
  DATUM_MORGEN="$TOMORROW" \
  python3 -c '
import os
with open(os.environ["PROMPT_FILE"]) as f:
    tpl = f.read()
for key in ("ROLE", "PARTNER_ROLE", "USER_NAME", "USER_FRIENDLY_NAME",
            "HUIDIG_TIJDSTIP", "DATUM_MORGEN"):
    tpl = tpl.replace("{{" + key + "}}", os.environ[key])
import sys
sys.stdout.write(tpl)
'
)

# Fetch context from fetch-context.sh
CONTEXT=$(bash "$PROJECT_DIR/scripts/fetch-context.sh")

# Optioneel: merge partner_voorstel (arg $1) in de context JSON.
PARTNER_VOORSTEL="${1:-}"
if [[ -n "$PARTNER_VOORSTEL" ]]; then
  CONTEXT=$(CONTEXT_JSON="$CONTEXT" PV="$PARTNER_VOORSTEL" python3 -c '
import json, os
c = json.loads(os.environ["CONTEXT_JSON"])
c["partner_voorstel"] = os.environ["PV"]
print(json.dumps(c, ensure_ascii=False))
')
fi

# Run Claude headless. --output-format text = platte response body op stdout.
RESPONSE=$("$CLAUDE_BIN" -p "$CONTEXT" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --output-format text 2>&1)

# Validate JSON. Strip per-ongeluk toegevoegde ```json fences.
RESPONSE_OUT="$RESPONSE" python3 -c '
import json, os, sys
raw = os.environ["RESPONSE_OUT"].strip()
if raw.startswith("```"):
    # Verwijder opening fence (```json of ```) en sluitend ```
    parts = raw.split("```", 2)
    if len(parts) >= 2:
        raw = parts[1]
        if raw.startswith("json\n"):
            raw = raw[5:]
        elif raw.startswith("json"):
            raw = raw[4:]
    raw = raw.rsplit("```", 1)[0].strip()
try:
    d = json.loads(raw)
    assert isinstance(d, dict), "top-level moet object zijn"
    assert "datum" in d, "missing datum"
    assert "blokken" in d, "missing blokken"
    print(json.dumps(d, ensure_ascii=False))
except Exception as e:
    print(f"run-claude: INVALID JSON from Claude: {e}\n---RAW---\n{raw[:1000]}",
          file=sys.stderr)
    sys.exit(1)
'

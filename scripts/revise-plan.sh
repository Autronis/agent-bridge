#!/usr/bin/env bash
# revise-plan.sh
# Tweede Claude-call met origineel plan + partner-reply → herziene plan-JSON.
# Flow: origineel plan + reply tekst → revise-plan.md system prompt →
# nieuwe plan-JSON op stdout.
#
# Usage:
#   scripts/revise-plan.sh <origineel-plan-json-path> <partner-reply-text>
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "revise-plan: config niet gevonden op $CONFIG_PATH" >&2
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
    print(val)
else:
    print(json.dumps(val))
' "$1"
}

USER_NAME=$(read_cfg user)
ROLE=$(read_cfg role_name)
PARTNER=$(read_cfg partner_role_name)
CLAUDE_BIN=$(read_cfg claude_binary)

PLAN_JSON="${1:?origineel plan JSON path required}"
PARTNER_REPLY="${2:?partner reply text required}"

if [[ ! -f "$PLAN_JSON" ]]; then
  echo "revise-plan: origineel plan JSON niet gevonden: $PLAN_JSON" >&2
  exit 1
fi

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "revise-plan: claude binary niet uitvoerbaar: $CLAUDE_BIN" >&2
  exit 1
fi

PROMPT_FILE="$PROJECT_DIR/prompts/revise-plan.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "revise-plan: prompt template niet gevonden: $PROMPT_FILE" >&2
  exit 1
fi

case "$USER_NAME" in
  sem) FRIENDLY="Sem" ;;
  syb) FRIENDLY="Syb" ;;
  *) echo "revise-plan: user moet sem of syb zijn (was: $USER_NAME)" >&2; exit 1 ;;
esac

# Datum morgen — zelfde logica als run-claude.sh.
if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
  TOMORROW=$(date -v+1d +%Y-%m-%d)
else
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)
fi

# Render system prompt met placeholders.
SYSTEM_PROMPT=$(
  PROMPT_FILE="$PROMPT_FILE" \
  ROLE="$ROLE" \
  PARTNER_ROLE="$PARTNER" \
  USER_NAME="$USER_NAME" \
  USER_FRIENDLY_NAME="$FRIENDLY" \
  DATUM_MORGEN="$TOMORROW" \
  python3 -c '
import os
with open(os.environ["PROMPT_FILE"]) as f:
    tpl = f.read()
for key in ("ROLE", "PARTNER_ROLE", "USER_NAME", "USER_FRIENDLY_NAME", "DATUM_MORGEN"):
    tpl = tpl.replace("{{" + key + "}}", os.environ[key])
import sys
sys.stdout.write(tpl)
'
)

# Context = fetch-context output (zelfde als oorspronkelijke run zodat Claude
# weet over taken / leads zonder een tweede API-call te hoeven doen wrappen).
ORIGINAL_CONTEXT=$(bash "$PROJECT_DIR/scripts/fetch-context.sh")

# Input voor Claude: origineel plan + partner reply + context.
INPUT_JSON=$(
  ORIG_PLAN="$(cat "$PLAN_JSON")" \
  REPLY="$PARTNER_REPLY" \
  CTX="$ORIGINAL_CONTEXT" \
  python3 -c '
import json, os
print(json.dumps({
    "origineel_plan": json.loads(os.environ["ORIG_PLAN"]),
    "partner_reply": os.environ["REPLY"],
    "context": json.loads(os.environ["CTX"]),
}, ensure_ascii=False))
'
)

# Run Claude.
CLAUDE_STDERR=$(mktemp)
RESPONSE=$("$CLAUDE_BIN" -p "$INPUT_JSON" \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --output-format text </dev/null 2>"$CLAUDE_STDERR")
if [[ -z "$RESPONSE" ]]; then
  echo "revise-plan: lege response van claude. stderr:" >&2
  cat "$CLAUDE_STDERR" >&2
  rm -f "$CLAUDE_STDERR"
  exit 1
fi
rm -f "$CLAUDE_STDERR"

# Strip code fences + valideer.
RESPONSE_OUT="$RESPONSE" python3 -c '
import json, os, sys
raw = os.environ["RESPONSE_OUT"].strip()
if raw.startswith("```"):
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
    print(f"revise-plan: INVALID JSON: {e}\n---RAW---\n{raw[:1000]}", file=sys.stderr)
    sys.exit(1)
'

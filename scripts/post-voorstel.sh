#!/usr/bin/env bash
# post-voorstel.sh
# Leest een plan JSON (output van run-claude.sh) en post een leesbare platte-tekst
# samenvatting naar #claude-handoffs via het gedeelde discord-bot script.
#
# Usage:
#   scripts/post-voorstel.sh <plan-json-path>
#
# Exit codes:
#   0 — bericht succesvol doorgegeven aan discord-bot
#   1 — config/plan fout
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "post-voorstel: config niet gevonden op $CONFIG_PATH" >&2
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

DISCORD_BOT_RAW=$(read_cfg discord_bot_script)
ROLE=$(read_cfg role_name)
USER_NAME=$(read_cfg user)

# Expand ~ in discord bot script path.
DISCORD_BOT="${DISCORD_BOT_RAW/#\~/$HOME}"

if [[ ! -x "$DISCORD_BOT" ]]; then
  echo "post-voorstel: discord bot script niet uitvoerbaar op $DISCORD_BOT" >&2
  exit 1
fi

PLAN_JSON="${1:?plan-json path required}"
if [[ ! -f "$PLAN_JSON" ]]; then
  echo "post-voorstel: plan JSON niet gevonden: $PLAN_JSON" >&2
  exit 1
fi

# Build human-readable message from plan JSON. Alles via env-vars (geen injection).
MESSAGE=$(PLAN_JSON="$PLAN_JSON" ROLE="$ROLE" USER_NAME="$USER_NAME" python3 <<'PY'
import json, os, sys

try:
    with open(os.environ["PLAN_JSON"]) as f:
        plan = json.load(f)
except Exception as e:
    sys.exit(f"kon plan JSON niet parsen: {e}")

if not isinstance(plan, dict):
    sys.exit("plan JSON top-level moet een object zijn")

role = os.environ["ROLE"]
user_upper = os.environ["USER_NAME"].upper()
datum = plan.get("datum", "?")

lines = [f"PLANNING-{user_upper} {role} voor {datum}", ""]
lines.append(f"Samenvatting: {plan.get('samenvatting','')}")
lines.append("")
lines.append("Blokken:")
for b in plan.get("blokken", []) or []:
    start = b.get("start", "?")
    eind = b.get("eind", "?")
    titel = b.get("titel", "")
    lines.append(f"  {start}-{eind}  {titel}")

team_taken = plan.get("team_taken_voorstel") or []
if team_taken:
    lines.append("")
    lines.append("Team-taken voorstel:")
    for t in team_taken:
        tid = t.get("taakId", "?")
        titel = t.get("titel", "")
        wie = t.get("wie", "?")
        reden = t.get("reden", "")
        lines.append(f"  [{tid}] {titel} -> {wie} ({reden})")

conflicts = plan.get("conflicts") or []
if conflicts:
    lines.append("")
    lines.append("Conflicts:")
    for c in conflicts:
        lines.append(f"  - {c}")

sys.stdout.write("\n".join(lines))
PY
)

"$DISCORD_BOT" send "$MESSAGE"

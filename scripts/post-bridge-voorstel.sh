#!/usr/bin/env bash
# post-bridge-voorstel.sh
# Post de `overleg` sectie van een plan JSON naar Discord #claude-handoffs.
# Partner ziet dit, reageert met BRIDGE-REPLY-<USER_UPPER> marker, waarna
# deze bridge-run revise-plan triggert en finaal committeert.
#
# Usage:
#   scripts/post-bridge-voorstel.sh <plan-json-path>
#
# Exit codes:
#   0 — posted (of niks te posten bij ontbrekende overleg-sectie)
#   1 — config/plan fout
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "post-bridge-voorstel: config niet gevonden op $CONFIG_PATH" >&2
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

PLAN_JSON="${1:?plan-json path required}"
if [[ ! -f "$PLAN_JSON" ]]; then
  echo "post-bridge-voorstel: plan JSON niet gevonden: $PLAN_JSON" >&2
  exit 1
fi

USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
PARTNER_UPPER=$([ "$USER_UPPER" = "SEM" ] && echo "SYB" || echo "SEM")

# Build the Discord message text. Single plain-text block so de partner-bot
# het direct kan parsen zonder JSON-intermediate.
BODY=$(PLAN_JSON="$PLAN_JSON" USER_UPPER="$USER_UPPER" PARTNER_UPPER="$PARTNER_UPPER" python3 <<'PY'
import json, os, sys
with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

overleg = plan.get("overleg") or {}
datum = plan.get("datum", "?")
user_up = os.environ["USER_UPPER"]
partner_up = os.environ["PARTNER_UPPER"]

lines = [f"BRIDGE-VOORSTEL {user_up} voor {datum}"]
lines.append(f"Reply met marker: BRIDGE-REPLY-{user_up}")
lines.append("")

beknopt = (overleg.get("beknopt_voorstel") or plan.get("samenvatting") or "").strip()
if beknopt:
    lines.append(beknopt)
    lines.append("")

team = overleg.get("team_taken") or []
if team:
    lines.append("Team-taken (wie pakt 'm?):")
    for t in team:
        voorkeur = t.get("voorkeur") or "?"
        reden = t.get("reden") or ""
        titel = t.get("titel") or ""
        line = f"- {titel} → voorkeur: {voorkeur}"
        if reden:
            line += f" ({reden})"
        lines.append(line)
    lines.append("")

vragen = overleg.get("vragen_aan_partner") or []
if vragen:
    lines.append("Vragen:")
    for v in vragen:
        lines.append(f"- {v}")
    lines.append("")

# Korte plan-samenvatting (titels + tijd) — zodat partner context heeft.
blokken = plan.get("blokken") or []
lines.append(f"Plan morgen ({len(blokken)} blokken):")
for b in blokken[:12]:
    lines.append(f"- {b.get('start','?')}-{b.get('eind','?')} {b.get('titel','')[:55]}")
if len(blokken) > 12:
    lines.append(f"- (+{len(blokken)-12} meer)")

print("\n".join(lines))
PY
)

if [[ -z "$BODY" ]]; then
  echo "post-bridge-voorstel: plan heeft geen overleg-inhoud, skip" >&2
  exit 0
fi

# Stuur. discord-bot.sh echoot bij success "Verzonden naar #handoffs (id: ...)".
"$DISCORD_BOT" send "$BODY" 2>&1 | tee -a /dev/stderr | tail -1

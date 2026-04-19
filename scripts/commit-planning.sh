#!/usr/bin/env bash
# commit-planning.sh
# Leest een plan JSON (output van run-claude.sh) en POST elk non-buffer blok
# naar /api/agenda op het dashboard. Logt successen en failures.
#
# Usage:
#   scripts/commit-planning.sh <plan-json-path>
#
# Stdout:
#   "<N> blokken gepland, <M> mislukt"
# Stderr (per failure):
#   "fail (<http_code>): <titel> — <response-snippet>"
#
# Exit codes:
#   0 — altijd (ook bij partial failure); check stdout/stderr voor details
#   1 — config of plan JSON fout
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "commit-planning: config niet gevonden op $CONFIG_PATH" >&2
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

DASHBOARD_URL=$(read_cfg dashboard_url)
API_KEY_FILE=$(read_cfg dashboard_api_key_file)

if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "commit-planning: api key file niet gevonden op $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(API_KEY_FILE="$API_KEY_FILE" python3 -c '
import json, os, sys
with open(os.environ["API_KEY_FILE"]) as f:
    cfg = json.load(f)
if "api_key" not in cfg:
    sys.exit("missing api_key in " + os.environ["API_KEY_FILE"])
print(cfg["api_key"])
')

PLAN_JSON="${1:?plan-json path required}"
if [[ ! -f "$PLAN_JSON" ]]; then
  echo "commit-planning: plan JSON niet gevonden: $PLAN_JSON" >&2
  exit 1
fi

# Voor elk blok: POST /api/agenda. Skip type=buffer blocks.
PLAN_JSON="$PLAN_JSON" URL="$DASHBOARD_URL" KEY="$API_KEY" python3 <<'PY'
import json, os, subprocess, sys

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

if not isinstance(plan, dict):
    sys.exit("plan JSON top-level moet een object zijn")

url = os.environ["URL"].rstrip("/")
key = os.environ["KEY"]
datum = plan.get("datum")
if not datum:
    sys.exit("plan JSON mist 'datum' veld")

ok, fail = 0, 0
for b in plan.get("blokken", []) or []:
    if b.get("type") == "buffer":
        continue
    start = b.get("start")
    eind = b.get("eind")
    titel = b.get("titel", "")
    if not start or not eind:
        fail += 1
        print(f"fail (-): {titel} — missing start/eind", file=sys.stderr)
        continue
    start_iso = f"{datum}T{start}:00"
    eind_iso = f"{datum}T{eind}:00"
    body = {
        "titel": titel,
        "omschrijving": b.get("toelichting", ""),
        "startDatum": start_iso,
        "eindDatum": eind_iso,
        "type": "taak" if b.get("type") == "taak" else "blok",
    }
    if b.get("taakId"):
        body["taakId"] = b["taakId"]
    r = subprocess.run(
        [
            "curl", "-s", "-w", "\nHTTP:%{http_code}",
            "-X", "POST", f"{url}/api/agenda",
            "-H", f"Authorization: Bearer {key}",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(body),
        ],
        capture_output=True, text=True,
    )
    body_out = r.stdout or ""
    parts = body_out.rsplit("HTTP:", 1)
    resp = parts[0].strip()
    code = parts[1].strip() if len(parts) > 1 else "?"
    if code.startswith("2") and '"error"' not in resp and '"fout"' not in resp:
        ok += 1
    else:
        fail += 1
        snippet = resp[:180].replace("\n", " ")
        print(f"fail ({code}): {titel} — {snippet}", file=sys.stderr)

print(f"{ok} blokken gepland, {fail} mislukt")
PY

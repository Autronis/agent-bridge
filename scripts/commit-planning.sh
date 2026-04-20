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

# BRIDGE_USER moet worden gezet door plan-avond.sh (sem|syb). Default 'vrij'
# zodat individuele runs zonder user-context niet failen.
BRIDGE_USER="${BRIDGE_USER:-vrij}"

# Step 1: reset any prior bridge-generated rows for this (datum, eigenaar).
# Silent on failure — endpoint may not exist on older dashboards, in which
# case we accept possible duplicates rather than abort.
PLAN_JSON="$PLAN_JSON" URL="$DASHBOARD_URL" KEY="$API_KEY" USER_NAME="$BRIDGE_USER" python3 <<'PY'
import json, os, subprocess, sys

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

datum = plan.get("datum")
if not datum:
    sys.exit(0)  # no datum, skip reset

url = os.environ["URL"].rstrip("/")
key = os.environ["KEY"]
eigenaar = os.environ["USER_NAME"]

r = subprocess.run(
    [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST", f"{url}/api/agenda/bridge-reset",
        "-H", f"Authorization: Bearer {key}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"datum": datum, "eigenaar": eigenaar}),
    ],
    capture_output=True, text=True,
)
code = (r.stdout or "?").strip()
if code.startswith("2"):
    print(f"bridge-reset: {datum} eigenaar={eigenaar} OK", file=sys.stderr)
else:
    print(f"bridge-reset: {code} (skipping, will tolerate dups)", file=sys.stderr)
PY

# Step 2: post each non-buffer block to /api/agenda with eigenaar + gemaaktDoor.
PLAN_JSON="$PLAN_JSON" URL="$DASHBOARD_URL" KEY="$API_KEY" USER_NAME="$BRIDGE_USER" python3 <<'PY'
import json, os, subprocess, sys

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

if not isinstance(plan, dict):
    sys.exit("plan JSON top-level moet een object zijn")

url = os.environ["URL"].rstrip("/")
key = os.environ["KEY"]
default_user = os.environ["USER_NAME"]
datum = plan.get("datum")
if not datum:
    sys.exit("plan JSON mist 'datum' veld")

valid_eigenaar = {"sem", "syb", "team", "vrij"}

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

    eigenaar = b.get("eigenaar") or default_user
    if eigenaar not in valid_eigenaar:
        # Claude can slip up — coerce to 'vrij' rather than failing the block.
        print(f"warn: ongeldige eigenaar '{eigenaar}' voor '{titel}', val terug op 'vrij'", file=sys.stderr)
        eigenaar = "vrij"

    body = {
        "titel": titel,
        "omschrijving": b.get("toelichting", ""),
        "startDatum": start_iso,
        "eindDatum": eind_iso,
        "type": "afspraak",
        "eigenaar": eigenaar,
        "gemaaktDoor": "bridge",
    }
    if isinstance(b.get("projectId"), int):
        body["projectId"] = b["projectId"]
    if isinstance(b.get("taakId"), int):
        body["taakId"] = b["taakId"]
    if isinstance(b.get("pijler"), str) and b["pijler"].strip():
        body["pijler"] = b["pijler"].strip()
    if isinstance(b.get("stappenplan"), list) and b["stappenplan"]:
        body["stappenplan"] = b["stappenplan"]
    if isinstance(b.get("aiContext"), str) and b["aiContext"].strip():
        body["aiContext"] = b["aiContext"].strip()
    if isinstance(b.get("geschatteDuurMinuten"), int) and b["geschatteDuurMinuten"] > 0:
        body["geschatteDuurMinuten"] = b["geschatteDuurMinuten"]
    # parallelActiviteit: nieuw format is object {titel, duurMin, pijler, cluster}
    # — we serialiseren naar JSON-string zodat het veld op sqlite TEXT past.
    # Oude string-format blijft ondersteund voor backward compat.
    pa = b.get("parallelActiviteit")
    if isinstance(pa, dict) and pa.get("titel"):
        body["parallelActiviteit"] = json.dumps(pa, ensure_ascii=False)
    elif isinstance(pa, str) and pa.strip():
        body["parallelActiviteit"] = pa.strip()
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

# Step 3: POST slimme_acties[] naar /api/slimme-acties-bridge.
# Vervangt de generieke slimme-taken-templates door concrete,
# Autronis-specifieke acties die Atlas/Autro vannacht gegenereerd heeft.
PLAN_JSON="$PLAN_JSON" URL="$DASHBOARD_URL" KEY="$API_KEY" python3 <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

acties = plan.get("slimme_acties") or []
if not acties:
    sys.exit(0)

# verlooptOp = start_of_tomorrow + 48h (acties zijn voor morgen; twee dagen
# geldigheid geeft Sem tijd om ze op te pakken ook als hij ze niet meteen
# ziet).
now = datetime.now(timezone.utc)
tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
verloopt = (tomorrow + timedelta(hours=48)).isoformat().replace("+00:00", "Z")

valid_voor = {"sem", "syb", "team"}
valid_prior = {"laag", "normaal", "hoog"}

payload = []
for a in acties:
    if not isinstance(a, dict) or not a.get("titel"):
        continue
    voor = a.get("voor") or "team"
    if voor not in valid_voor:
        voor = "team"
    prio = a.get("prioriteit") or "normaal"
    if prio not in valid_prior:
        prio = "normaal"
    payload.append({
        "titel": a["titel"],
        "beschrijving": a.get("beschrijving") or None,
        "cluster": a.get("cluster") or None,
        "pijler": a.get("pijler") or None,
        "duurMin": a.get("duurMin"),
        "voor": voor,
        "prioriteit": prio,
        "bronTaakId": a.get("bronTaakId"),
        "verlooptOp": verloopt,
    })

if not payload:
    sys.exit(0)

url = os.environ["URL"].rstrip("/")
key = os.environ["KEY"]
r = subprocess.run(
    [
        "curl", "-s", "-w", "\nHTTP:%{http_code}",
        "-X", "POST", f"{url}/api/slimme-acties-bridge",
        "-H", f"Authorization: Bearer {key}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"acties": payload}),
    ],
    capture_output=True, text=True,
)
body_out = r.stdout or ""
parts = body_out.rsplit("HTTP:", 1)
code = parts[1].strip() if len(parts) > 1 else "?"
if code.startswith("2"):
    print(f"slimme-acties: {len(payload)} gepost", file=sys.stderr)
else:
    snippet = (parts[0] or "")[:180].replace("\n", " ")
    print(f"slimme-acties FAIL ({code}): {snippet}", file=sys.stderr)
PY

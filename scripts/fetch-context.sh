#!/usr/bin/env bash
# fetch-context.sh
# Verzamelt dashboard context (taken, slimme taken, agenda morgen, uren deze week)
# en print één compact JSON object naar stdout. Wordt gebruikt door de avond-planning
# bridge om Claude's plan-input op te bouwen.
set -euo pipefail

CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "fetch-context: config niet gevonden op $CONFIG_PATH" >&2
  echo "fetch-context: kopieer config/settings.example.json naar $CONFIG_PATH" >&2
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
DASHBOARD_URL=$(read_cfg dashboard_url)
API_KEY_FILE_RAW=$(read_cfg dashboard_api_key_file)

# Expand ~ in api-key file path.
API_KEY_FILE="${API_KEY_FILE_RAW/#\~/$HOME}"

if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "fetch-context: API key file niet gevonden: $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(API_KEY_FILE="$API_KEY_FILE" python3 -c '
import json, os, sys
with open(os.environ["API_KEY_FILE"]) as f:
    data = json.load(f)
if "api_key" not in data:
    sys.exit("api_key missing in " + os.environ["API_KEY_FILE"])
print(data["api_key"])
')

if [[ -z "$API_KEY" ]]; then
  echo "fetch-context: lege API key" >&2
  exit 1
fi

# Morgen datum — werkt op macOS (BSD date) én git-bash/Linux (GNU date).
if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
  MORGEN=$(date -v+1d +%Y-%m-%d)   # BSD / macOS
else
  MORGEN=$(date -d "tomorrow" +%Y-%m-%d)   # GNU / Linux / git-bash / MSYS
fi

# Temp files voor responses. Gebruik PID + random zodat parallel-runs niet botsen.
TMP_BASE="${TMPDIR:-/tmp}/agent-bridge-$$-$RANDOM"
TAKEN_FILE="${TMP_BASE}-taken.json"
SLIM_FILE="${TMP_BASE}-slim.json"
AGENDA_FILE="${TMP_BASE}-agenda.json"
UREN_FILE="${TMP_BASE}-uren.json"
GTM_FILE="${TMP_BASE}-gtm.json"

cleanup() {
  rm -f "$TAKEN_FILE" "$SLIM_FILE" "$AGENDA_FILE" "$UREN_FILE" "$GTM_FILE"
}
trap cleanup EXIT

# fetch_endpoint <output_file> <url_path> <label>
# Schrijft response body naar output_file. Print warning naar stderr bij non-2xx of curl fail.
# Zet bij fout een leeg JSON object in het output file zodat parsers niet breken.
fetch_endpoint() {
  local out_file="$1"
  local path="$2"
  local label="$3"
  local http_code
  http_code=$(curl -s -o "$out_file" -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    "${DASHBOARD_URL}${path}" || echo "000")
  if [[ "$http_code" != 2* ]]; then
    echo "fetch-context: warn: $label returned HTTP $http_code (${path})" >&2
    echo '{}' > "$out_file"
  fi
}

fetch_endpoint "$TAKEN_FILE"  "/api/taken?status=open,bezig"                     "taken"
fetch_endpoint "$SLIM_FILE"   "/api/taken/slim"                                  "slimme_taken"
fetch_endpoint "$AGENDA_FILE" "/api/agenda?van=${MORGEN}&tot=${MORGEN}"          "agenda_morgen"
fetch_endpoint "$UREN_FILE"   "/api/briefing/uren-deze-week"                     "uren_week"
fetch_endpoint "$GTM_FILE"    "/api/gtm-ritme"                                   "gtm_ritme"

# Compose the final JSON. Alle inputs via env-vars (geen string injection).
USER_NAME="$USER_NAME" \
DATUM_MORGEN="$MORGEN" \
TAKEN_FILE="$TAKEN_FILE" \
SLIM_FILE="$SLIM_FILE" \
AGENDA_FILE="$AGENDA_FILE" \
UREN_FILE="$UREN_FILE" \
GTM_FILE="$GTM_FILE" \
python3 <<'PY'
import json, os, sys

def load_json(path, label):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        print(f"fetch-context: warn: kon {label} niet parsen: {e}", file=sys.stderr)
        return {}

def pick_list(doc, keys):
    """Return the first list-valued entry among keys, or [] if none found."""
    if not isinstance(doc, dict):
        return []
    for k in keys:
        v = doc.get(k)
        if isinstance(v, list):
            return v
    return []

taken_doc  = load_json(os.environ["TAKEN_FILE"],  "taken")
slim_doc   = load_json(os.environ["SLIM_FILE"],   "slimme_taken")
agenda_doc = load_json(os.environ["AGENDA_FILE"], "agenda_morgen")
uren_doc   = load_json(os.environ["UREN_FILE"],   "uren_week")
gtm_doc    = load_json(os.environ["GTM_FILE"],    "gtm_ritme")

# Warn on API-level error envelopes ({fout: "..."}).
for label, doc in (("taken", taken_doc), ("slimme_taken", slim_doc),
                   ("agenda_morgen", agenda_doc), ("uren_week", uren_doc),
                   ("gtm_ritme", gtm_doc)):
    if isinstance(doc, dict) and "fout" in doc:
        print(f"fetch-context: warn: {label} API returned fout: {doc.get('fout')}", file=sys.stderr)

taken_list   = pick_list(taken_doc,  ["taken"])
# /api/taken/slim envelope is inconsistent across versions — probeer in volgorde.
slim_list    = pick_list(slim_doc,   ["actief", "templates", "slimmeTaken", "data"])
agenda_list  = pick_list(agenda_doc, ["items"])
gtm_list     = pick_list(gtm_doc,    ["slots"])

uren_week = uren_doc if isinstance(uren_doc, dict) and "fout" not in uren_doc else {}

out = {
    "user": os.environ["USER_NAME"],
    "datum_morgen": os.environ["DATUM_MORGEN"],
    "taken": taken_list,
    "slimme_taken": slim_list,
    "agenda_morgen": agenda_list,
    "uren_week": uren_week,
    "gtm_ritme": gtm_list,
}
print(json.dumps(out, ensure_ascii=False))
PY

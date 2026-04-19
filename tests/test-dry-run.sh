#!/usr/bin/env bash
# test-dry-run.sh
# End-to-end dry run voor plan-avond.sh. Forceert dry_run=true in de config,
# draait de volledige pipeline (fetch context → Claude → Discord post), en
# herstelt de originele config via trap EXIT — ook bij failure.
#
# Verificatie post-run gebeurt handmatig:
#   - Discord #claude-handoffs moet een PLANNING-<USER> post bevatten
#   - Dashboard agenda voor morgen moet GEEN nieuwe entries hebben
#
# Usage:
#   bash tests/test-dry-run.sh
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG="$HOME/.config/autronis/agent-bridge.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "test-dry-run: config niet gevonden op $CONFIG" >&2
  exit 1
fi

# Backup config inhoud in memory — restore via trap (ook bij failure).
ORIG=$(cat "$CONFIG")
trap 'printf "%s" "$ORIG" > "$CONFIG"; echo "[trap] config restored"' EXIT

# Force dry_run=true.
CONFIG="$CONFIG" python3 -c '
import json, os
p = os.environ["CONFIG"]
with open(p) as f:
    d = json.load(f)
d["dry_run"] = True
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
'

echo "=== Config nu dry_run=true ==="
grep -E '"dry_run"' "$CONFIG" || true
echo ""

echo "=== Running plan-avond.sh (dry_run=true) ==="
bash "$PROJECT_DIR/scripts/plan-avond.sh"
RC=$?

echo ""
echo "=== Recente files in logs/ ==="
ls -lt "$PROJECT_DIR/logs/" | head -5

echo ""
echo "=== Dry run klaar (exit $RC). Check Discord #claude-handoffs voor PLANNING-* post ==="

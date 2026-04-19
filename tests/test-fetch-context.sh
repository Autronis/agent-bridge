#!/usr/bin/env bash
# Smoke test voor fetch-context.sh.
# Roept het script aan en verifieert de JSON-shape.
set -euo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.."

OUT=$(scripts/fetch-context.sh)

echo "$OUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert "user" in d, "missing user"
assert "datum_morgen" in d, "missing datum_morgen"
assert "taken" in d and isinstance(d["taken"], list), "taken not list"
assert "slimme_taken" in d and isinstance(d["slimme_taken"], list), "slimme_taken not list"
assert "agenda_morgen" in d and isinstance(d["agenda_morgen"], list), "agenda not list"
assert "uren_week" in d and isinstance(d["uren_week"], dict), "uren_week not dict"
user = d["user"]
n_taken = len(d["taken"])
n_slim = len(d["slimme_taken"])
print("OK: user={} taken={} slim={}".format(user, n_taken, n_slim))
'

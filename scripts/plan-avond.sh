#!/usr/bin/env bash
# plan-avond.sh
# Main orchestrator voor het avond-plan ritueel. Flow:
#   1. Load config, detect user (sem/syb).
#   2. Voor syb (Autro): lees laatste 20 Discord messages, extract Atlas'
#      planning post voor morgen als partner_voorstel.
#   3. Run run-claude.sh met partner_voorstel → plan JSON.
#   4. Op Claude-failure: alert naar Discord, exit 1.
#   5. Schrijf plan JSON naar logs/plan_<timestamp>.json.
#   6. Run post-voorstel.sh → Discord samenvatting.
#   7. Tenzij dry_run: run commit-planning.sh → agenda entries.
#
# Usage:
#   scripts/plan-avond.sh
#
# Exit codes:
#   0 — plan gemaakt en (voor zover van toepassing) gecommit
#   1 — config fout of Claude heeft geen geldig plan gegenereerd
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH_DEFAULT="$HOME/.config/autronis/agent-bridge.json"
CONFIG_PATH="${AGENT_BRIDGE_CONFIG:-$CONFIG_PATH_DEFAULT}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "plan-avond: config niet gevonden op $CONFIG_PATH" >&2
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
DISCORD_BOT=$(read_cfg discord_bot_script)
DRY_RUN=$(read_cfg dry_run)

if [[ ! -x "$DISCORD_BOT" ]]; then
  echo "plan-avond: discord bot script niet uitvoerbaar op $DISCORD_BOT" >&2
  exit 1
fi

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG="$LOG_DIR/plan-avond_$TIMESTAMP.log"
PLAN_FILE="$LOG_DIR/plan_$TIMESTAMP.json"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "Start plan-avond voor user=$USER_NAME (dry_run=$DRY_RUN)"

# Autro (syb) leest Atlas' voorstel eerst — Autro draait 15 min later.
PARTNER_VOORSTEL=""
if [[ "$USER_NAME" == "syb" ]]; then
  if date -v+1d +%Y-%m-%d >/dev/null 2>&1; then
    TOMORROW=$(date -v+1d +%Y-%m-%d)   # BSD / macOS
  else
    TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)   # GNU / Linux / git-bash / MSYS
  fi
  log "Autro: lees laatste Atlas planning-post voor $TOMORROW..."
  MSGS=$("$DISCORD_BOT" read 20 2>/dev/null || echo "")
  # Extract Atlas' block: zoek marker "PLANNING-SEM Atlas voor <datum>",
  # pak alles tot de volgende PLANNING- header of max 1500 chars.
  PARTNER_VOORSTEL=$(MSGS="$MSGS" TOMORROW="$TOMORROW" python3 -c '
import os, re
msgs = os.environ["MSGS"]
tomorrow = os.environ["TOMORROW"]
marker = f"PLANNING-SEM Atlas voor {tomorrow}"
idx = msgs.find(marker)
if idx == -1:
    print("", end="")
else:
    tail = msgs[idx:]
    # Stop bij volgende PLANNING- header, of max 1500 chars.
    m = re.search(r"\nPLANNING-", tail[len(marker):])
    end = len(marker) + (m.start() if m else min(len(tail) - len(marker), 1500))
    print(tail[:end].strip())
')
  if [[ -n "$PARTNER_VOORSTEL" ]]; then
    CHARS=$(printf '%s' "$PARTNER_VOORSTEL" | wc -c | tr -d ' ')
    log "Atlas voorstel gevonden ($CHARS chars)"
  else
    log "Geen Atlas voorstel gevonden — Autro plant standalone"
  fi
fi

# Run Claude.
log "Run Claude..."
set +e
PLAN=$(bash "$PROJECT_DIR/scripts/run-claude.sh" "$PARTNER_VOORSTEL" 2>>"$LOG")
CLAUDE_RC=$?
set -e

if [[ $CLAUDE_RC -ne 0 ]]; then
  log "Claude mislukt (exit $CLAUDE_RC)"
  USER_UPPER=$(printf '%s' "$USER_NAME" | tr '[:lower:]' '[:upper:]')
  "$DISCORD_BOT" send "PLANNING-$USER_UPPER FOUT: Claude kon geen plan maken. Log: $LOG" 2>&1 | tee -a "$LOG" || true
  exit 1
fi

printf '%s\n' "$PLAN" > "$PLAN_FILE"
log "Plan geschreven naar $PLAN_FILE"

# Post naar Discord.
log "Post voorstel naar Discord..."
bash "$PROJECT_DIR/scripts/post-voorstel.sh" "$PLAN_FILE" 2>&1 | tee -a "$LOG"

# Commit naar dashboard (tenzij dry-run).
case "$DRY_RUN" in
  True|true|1)
    log "DRY RUN: skip commit-planning"
    ;;
  *)
    log "Commit blokken naar dashboard..."
    bash "$PROJECT_DIR/scripts/commit-planning.sh" "$PLAN_FILE" 2>&1 | tee -a "$LOG"
    ;;
esac

log "Klaar"

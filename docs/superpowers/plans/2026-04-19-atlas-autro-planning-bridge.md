# Atlas-Autro Planning Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Elke avond 20:30–21:15 maken Atlas (Sem's Claude) en Autro (Syb's Claude) autonoom een planning voor de volgende dag, overleggen kort over gedeelde team-taken via Discord, en schrijven tijdsblokken in de dashboard-agenda zodat 's ochtends de dag klaarstaat.

**Architecture:** launchd-cron op elke Mac triggert een `plan-avond.sh` script dat `claude -p` headless aanroept met context uit het dashboard (taken, slimme-acties, bestaande agenda, focus-log). Claude genereert een tijdsblok-plan via bestaand `/api/agenda/ai-plan` endpoint, post samenvatting + team-taak voorstel naar Discord `#claude-handoffs`, en committeert blokken naar `/api/agenda` (→ Google Calendar). Atlas start 20:30, Autro leest Atlas' post om 20:45 en past eigen plan aan bij team-conflicten.

**Tech Stack:** Bash (script), Claude Code CLI (`claude -p`), Dashboard REST API (bestaand, Bearer auth), Discord REST via `discord-bot.sh` (bestaand), macOS launchd.

---

## File Structure

Nieuwe repo: `/Users/semmiegijs/Autronis/Projects/agent-bridge/` gedeeld via `github.com/Autronis/agent-bridge`.

- `scripts/plan-avond.sh` — main entry (detecteert user sem/syb, orchestreert flow)
- `scripts/fetch-context.sh` — haalt dashboard data op (taken, slim, agenda, uren) → JSON
- `scripts/run-claude.sh` — wrapper om `claude -p` met system prompt + context
- `scripts/post-voorstel.sh` — wrapper om `discord-bot.sh` voor formatted planning-post
- `scripts/commit-planning.sh` — POSTet tijdsblokken naar `/api/agenda`
- `scripts/install.sh` — detecteert user, installeert launchd plist, loads
- `scripts/uninstall.sh` — unload + cleanup
- `prompts/plan-avond.md` — shared system prompt (met `{{ROLE}}` placeholder: Atlas of Autro)
- `config/settings.example.json` — template; echte lokaal als `~/.config/autronis/agent-bridge.json`
- `launchd/com.autronis.plan-avond.plist.template` — launchd plist template
- `tests/test-fetch-context.sh` — smoke test fetch flow
- `tests/test-dry-run.sh` — volledige dry-run zonder side effects
- `README.md` — installatie + troubleshooting voor beide Macs
- `CLAUDE.md` — project context voor future Claude sessions
- `.gitignore` — sluit `.env`, logs uit

---

## Glossary

- **Atlas**: Claude Code instance op Sem's Mac. User-id in dashboard = `sem` (user id 1).
- **Autro**: Claude Code instance op Syb's Mac. User-id = `syb` (user id 2).
- **Team-taak**: Taak met `eigenaar='team'` in `taken` tabel — kan door beiden worden opgepakt.
- **Dagplan**: JSON `{ datum, blokken: [{ start, eind, titel, taakId?, type }] }` die naar `/api/agenda` wordt gepost.
- **Overleg-bericht**: Discord post naar `#claude-handoffs` met prefix `PLANNING-[SEM|SYB]` voor parseable dedup.

---

## Task 1: Config + Install Foundation

**Files:**
- Create: `config/settings.example.json`
- Create: `scripts/install.sh`
- Create: `scripts/uninstall.sh`
- Create: `launchd/com.autronis.plan-avond.plist.template`
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Lokale config en runtime artefacten
config/settings.json
*.log
.DS_Store
/launchd/*.installed.plist
```

- [ ] **Step 2: Write `config/settings.example.json`**

```json
{
  "user": "sem",
  "role_name": "Atlas",
  "partner_role_name": "Autro",
  "atlas_start_time": "20:30",
  "autro_start_time": "20:45",
  "dashboard_url": "https://dashboard.autronis.nl",
  "dashboard_api_key_file": "~/.config/autronis/claude-sync.json",
  "discord_bot_script": "~/.claude/scripts/discord-bot.sh",
  "planning_channel": "claude-handoffs",
  "claude_binary": "/opt/homebrew/bin/claude",
  "dry_run": false,
  "log_dir": "~/Autronis/Projects/agent-bridge/logs"
}
```

- [ ] **Step 3: Write `launchd/com.autronis.plan-avond.plist.template`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autronis.plan-avond</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__PROJECT_DIR__/scripts/plan-avond.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>__HOUR__</integer>
        <key>Minute</key>
        <integer>__MINUTE__</integer>
    </dict>
    <key>WorkingDirectory</key>
    <string>__PROJECT_DIR__</string>
    <key>StandardOutPath</key>
    <string>__PROJECT_DIR__/logs/plan-avond.log</string>
    <key>StandardErrorPath</key>
    <string>__PROJECT_DIR__/logs/plan-avond-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
```

- [ ] **Step 4: Write `scripts/install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH="$HOME/.config/autronis/agent-bridge.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config niet gevonden. Kopieer config/settings.example.json naar $CONFIG_PATH en pas aan."
  exit 1
fi

USER_NAME=$(python3 -c "import json,os,sys; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['user'])")
ATLAS_TIME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['atlas_start_time'])")
AUTRO_TIME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG_PATH')))['autro_start_time'])")

if [[ "$USER_NAME" == "sem" ]]; then TIME="$ATLAS_TIME"; else TIME="$AUTRO_TIME"; fi
HOUR=$(echo "$TIME" | cut -d: -f1)
MIN=$(echo "$TIME" | cut -d: -f2)

mkdir -p "$PROJECT_DIR/logs"
PLIST_OUT="$HOME/Library/LaunchAgents/com.autronis.plan-avond.plist"

sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MIN|g" \
    "$PROJECT_DIR/launchd/com.autronis.plan-avond.plist.template" > "$PLIST_OUT"

launchctl unload "$PLIST_OUT" 2>/dev/null || true
launchctl load -w "$PLIST_OUT"
echo "Installed for user=$USER_NAME at $TIME. Check: launchctl list | grep plan-avond"
```

- [ ] **Step 5: Write `scripts/uninstall.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.autronis.plan-avond.plist"
[[ -f "$PLIST" ]] && launchctl unload "$PLIST" && rm "$PLIST"
echo "Uninstalled."
```

- [ ] **Step 6: Make scripts executable + first commit**

```bash
chmod +x scripts/*.sh
git add .
git commit -m "feat(agent-bridge): scaffold config + launchd installer"
```

---

## Task 2: Context Fetcher

**Files:**
- Create: `scripts/fetch-context.sh`
- Create: `tests/test-fetch-context.sh`

**Doel:** verzamelt alles wat Claude nodig heeft om morgenochtend te plannen. Output = compact JSON naar stdout.

- [ ] **Step 1: Write `scripts/fetch-context.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG="$HOME/.config/autronis/agent-bridge.json"
DASHBOARD_URL=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['dashboard_url'])")
API_KEY_FILE=$(python3 -c "import json,os; print(os.path.expanduser(json.load(open(os.path.expanduser('$CONFIG')))['dashboard_api_key_file']))")
API_KEY=$(python3 -c "import json,os; print(json.load(open('$API_KEY_FILE'))['api_key'])")
USER_NAME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['user'])")

TOMORROW=$(date -v+1d +%Y-%m-%d)

# Fetch: open taken, slimme taken, agenda-morgen, uren-deze-week, focus-recent
TAKEN=$(curl -s "$DASHBOARD_URL/api/taken?status=open,bezig" -H "Authorization: Bearer $API_KEY")
SLIM=$(curl -s "$DASHBOARD_URL/api/taken/slim" -H "Authorization: Bearer $API_KEY")
AGENDA=$(curl -s "$DASHBOARD_URL/api/agenda?van=$TOMORROW&tot=$TOMORROW" -H "Authorization: Bearer $API_KEY")
UREN=$(curl -s "$DASHBOARD_URL/api/briefing/uren-deze-week" -H "Authorization: Bearer $API_KEY")

python3 <<PY
import json
print(json.dumps({
    "user": "$USER_NAME",
    "datum_morgen": "$TOMORROW",
    "taken": json.loads("""$TAKEN""").get("taken", []),
    "slimme_taken": json.loads("""$SLIM""").get("actief", []),
    "agenda_morgen": json.loads("""$AGENDA""").get("items", []),
    "uren_week": json.loads("""$UREN""")
}, ensure_ascii=False))
PY
```

- [ ] **Step 2: Write `tests/test-fetch-context.sh`**

```bash
#!/usr/bin/env bash
# Smoke test: fetch-context moet valid JSON returnen met alle keys
set -euo pipefail
cd "$( dirname "${BASH_SOURCE[0]}" )/.."
OUT=$(scripts/fetch-context.sh)
echo "$OUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'user' in d, 'missing user'
assert 'datum_morgen' in d, 'missing datum_morgen'
assert 'taken' in d and isinstance(d['taken'], list), 'taken not list'
assert 'slimme_taken' in d and isinstance(d['slimme_taken'], list), 'slimme_taken not list'
assert 'agenda_morgen' in d and isinstance(d['agenda_morgen'], list), 'agenda not list'
print(f'OK: user={d[\"user\"]} taken={len(d[\"taken\"])} slim={len(d[\"slimme_taken\"])}')"
```

- [ ] **Step 3: Run smoke test**

Run: `bash tests/test-fetch-context.sh`
Expected: `OK: user=sem taken=N slim=M`

- [ ] **Step 4: Commit**

```bash
git add scripts/fetch-context.sh tests/test-fetch-context.sh
git commit -m "feat(agent-bridge): fetch-context aggregates dashboard data"
```

---

## Task 3: Planning Prompt

**Files:**
- Create: `prompts/plan-avond.md`

- [ ] **Step 1: Write `prompts/plan-avond.md`**

```markdown
# Plan-avond system prompt

Je bent {{ROLE}}, de AI agent die {{USER_FRIENDLY_NAME}} helpt met dagplanning. Het is nu {{HUIDIG_TIJDSTIP}} en je taak is een planning voor morgen ({{DATUM_MORGEN}}) te maken.

## Context die je krijgt

Je ontvangt via stdin een JSON met:
- `taken[]` — openstaande taken (titel, fase, cluster, prioriteit, geschatteDuur, eigenaar, deadline)
- `slimme_taken[]` — beschikbare slimme-taak templates (uit sidebar /taken)
- `agenda_morgen[]` — wat er al gepland staat (meetings, vaste blokken)
- `uren_week` — hoeveel uur er deze week al is gewerkt
- `partner_voorstel` — (mogelijk leeg) vorige planning-post van {{PARTNER_ROLE}} voor dezelfde dag

## Regels

1. **Werk alleen met taken waar `eigenaar` in `["{{USER_NAME}}", "team", "vrij"]` staat.** Negeer andermans werk.
2. **Bestaande agenda-items respecteren.** Plan niet over meetings heen.
3. **Werkdag** = 09:00–17:30 default, met lunch 12:30–13:30 vrij tenzij genoemd.
4. **Deep-work blokken van 90 min** voor complexe taken (cluster = backend-infra of frontend). Korte taken (15–30 min) cluster je in één blok.
5. **Als `partner_voorstel` team-taken claimt**, pak die niet. Post een notitie.
6. **Als een team-taak voor beiden open is**, suggereer wie 'm beter kan doen (gebruik cluster-expertise heuristic).
7. **Max 6 uur productief gepland** per dag. Laat buffer.
8. **Prioriteit**: deadline vandaag/morgen → hoog → normaal → laag. Overschrijdende deadlines altijd eerst.

## Output format (JSON, ALLEEN JSON, geen markdown)

```json
{
  "datum": "{{DATUM_MORGEN}}",
  "blokken": [
    {
      "start": "09:00",
      "eind": "10:30",
      "titel": "Korte titel",
      "taakId": 123,
      "type": "taak|cluster|meeting|buffer",
      "toelichting": "1 zin waarom"
    }
  ],
  "team_taken_voorstel": [
    { "taakId": 456, "titel": "...", "wie": "{{USER_NAME}}", "reden": "cluster=backend-infra past" }
  ],
  "conflicts": [],
  "samenvatting": "2 zinnen: wat is het karakter van de dag, waar zit de focus"
}
```

Geen `<thinking>`, geen markdown code fences, geen extra uitleg. Alleen de JSON.
```

- [ ] **Step 2: Commit**

```bash
git add prompts/plan-avond.md
git commit -m "feat(agent-bridge): system prompt voor plan-avond"
```

---

## Task 4: Claude Runner

**Files:**
- Create: `scripts/run-claude.sh`

**Doel:** wrapper die context + prompt combineert en `claude -p` aanroept, valideert JSON output.

- [ ] **Step 1: Write `scripts/run-claude.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG="$HOME/.config/autronis/agent-bridge.json"

USER_NAME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['user'])")
ROLE=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['role_name'])")
PARTNER=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['partner_role_name'])")
CLAUDE_BIN=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['claude_binary'])")
NOW=$(date '+%Y-%m-%d %H:%M')
TOMORROW=$(date -v+1d +%Y-%m-%d)
FRIENDLY="Sem"; [[ "$USER_NAME" == "syb" ]] && FRIENDLY="Syb"

# Render system prompt
SYSTEM_PROMPT=$(sed \
  -e "s|{{ROLE}}|$ROLE|g" \
  -e "s|{{PARTNER_ROLE}}|$PARTNER|g" \
  -e "s|{{USER_NAME}}|$USER_NAME|g" \
  -e "s|{{USER_FRIENDLY_NAME}}|$FRIENDLY|g" \
  -e "s|{{HUIDIG_TIJDSTIP}}|$NOW|g" \
  -e "s|{{DATUM_MORGEN}}|$TOMORROW|g" \
  "$PROJECT_DIR/prompts/plan-avond.md")

# Context via stdin
CONTEXT=$(bash "$PROJECT_DIR/scripts/fetch-context.sh")
# Optioneel: partner voorstel meenemen als 2e arg aanwezig
PARTNER_VOORSTEL="${1:-}"
if [[ -n "$PARTNER_VOORSTEL" ]]; then
  CONTEXT=$(python3 -c "
import sys, json
c = json.loads('''$CONTEXT''')
c['partner_voorstel'] = '''$PARTNER_VOORSTEL'''
print(json.dumps(c, ensure_ascii=False))
")
fi

# Run Claude headless
RESPONSE=$("$CLAUDE_BIN" -p "$CONTEXT" --append-system-prompt "$SYSTEM_PROMPT" --output-format text 2>&1)

# Validate JSON
echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    assert 'datum' in d, 'missing datum'
    assert 'blokken' in d, 'missing blokken'
    print(json.dumps(d, ensure_ascii=False))
except Exception as e:
    print(f'INVALID JSON from Claude: {e}', file=sys.stderr)
    sys.exit(1)
"
```

- [ ] **Step 2: Commit**

```bash
chmod +x scripts/run-claude.sh
git add scripts/run-claude.sh
git commit -m "feat(agent-bridge): claude runner met prompt templating"
```

---

## Task 5: Discord Poster

**Files:**
- Create: `scripts/post-voorstel.sh`

- [ ] **Step 1: Write `scripts/post-voorstel.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: post-voorstel.sh <plan-json-path>

CONFIG="$HOME/.config/autronis/agent-bridge.json"
DISCORD_BOT=$(python3 -c "import json,os; print(os.path.expanduser(json.load(open(os.path.expanduser('$CONFIG')))['discord_bot_script']))")
ROLE=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['role_name'])")
USER_NAME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['user'])")

PLAN_JSON="$1"
MESSAGE=$(python3 <<PY
import json
d = json.load(open("$PLAN_JSON"))
lines = [f"PLANNING-${USER_NAME^^} $ROLE voor {d['datum']}"]
lines.append("")
lines.append(f"Samenvatting: {d.get('samenvatting','')}")
lines.append("")
lines.append("Blokken:")
for b in d["blokken"]:
    lines.append(f"  {b['start']}-{b['eind']}  {b['titel']}")
if d.get("team_taken_voorstel"):
    lines.append("")
    lines.append("Team-taken voorstel:")
    for t in d["team_taken_voorstel"]:
        lines.append(f"  [{t['taakId']}] {t['titel']} -> {t['wie']} ({t['reden']})")
if d.get("conflicts"):
    lines.append("")
    lines.append("Conflicts:")
    for c in d["conflicts"]:
        lines.append(f"  - {c}")
print("\n".join(lines))
PY
)

"$DISCORD_BOT" send "$MESSAGE"
```

- [ ] **Step 2: Commit**

```bash
chmod +x scripts/post-voorstel.sh
git add scripts/post-voorstel.sh
git commit -m "feat(agent-bridge): discord poster voor planning voorstel"
```

---

## Task 6: Agenda Committer

**Files:**
- Create: `scripts/commit-planning.sh`

**Doel:** plaatst elk blok uit plan-JSON in dashboard agenda via `POST /api/agenda`. Dit triggert auto-sync naar Google Calendar (als user het aan heeft).

- [ ] **Step 1: Write `scripts/commit-planning.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: commit-planning.sh <plan-json-path>

CONFIG="$HOME/.config/autronis/agent-bridge.json"
DASHBOARD_URL=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['dashboard_url'])")
API_KEY_FILE=$(python3 -c "import json,os; print(os.path.expanduser(json.load(open(os.path.expanduser('$CONFIG')))['dashboard_api_key_file']))")
API_KEY=$(python3 -c "import json,os; print(json.load(open('$API_KEY_FILE'))['api_key'])")

PLAN_JSON="$1"
DATUM=$(python3 -c "import json; print(json.load(open('$PLAN_JSON'))['datum'])")

# Voor elke blok: POST /api/agenda
python3 <<PY
import json, os, subprocess
d = json.load(open("$PLAN_JSON"))
url = "$DASHBOARD_URL"
key = "$API_KEY"
datum = d["datum"]
ok, fail = 0, 0
for b in d["blokken"]:
    if b.get("type") == "buffer":
        continue
    start_iso = f"{datum}T{b['start']}:00"
    eind_iso = f"{datum}T{b['eind']}:00"
    body = {
        "titel": b["titel"],
        "omschrijving": b.get("toelichting", ""),
        "startDatum": start_iso,
        "eindDatum": eind_iso,
        "type": "taak" if b.get("type") == "taak" else "blok",
    }
    if b.get("taakId"):
        body["taakId"] = b["taakId"]
    r = subprocess.run(
        ["curl", "-s", "-X", "POST", f"{url}/api/agenda",
         "-H", f"Authorization: Bearer {key}",
         "-H", "Content-Type: application/json",
         "-d", json.dumps(body)],
        capture_output=True, text=True
    )
    if r.returncode == 0 and '"error"' not in r.stdout:
        ok += 1
    else:
        fail += 1
        print(f"fail: {b['titel']} — {r.stdout[:120]}", file=__import__('sys').stderr)
print(f"{ok} blokken gepland, {fail} mislukt")
PY
```

- [ ] **Step 2: Commit**

```bash
chmod +x scripts/commit-planning.sh
git add scripts/commit-planning.sh
git commit -m "feat(agent-bridge): commit blokken naar /api/agenda"
```

---

## Task 7: Main Orchestrator

**Files:**
- Create: `scripts/plan-avond.sh`

**Doel:** Atlas om 20:30 loopt direct. Autro om 20:45 leest eerst Atlas' post uit Discord en geeft die als `partner_voorstel` mee aan Claude.

- [ ] **Step 1: Write `scripts/plan-avond.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG="$HOME/.config/autronis/agent-bridge.json"
LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG="$LOG_DIR/plan-avond_$TIMESTAMP.log"

USER_NAME=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['user'])")
DISCORD_BOT=$(python3 -c "import json,os; print(os.path.expanduser(json.load(open(os.path.expanduser('$CONFIG')))['discord_bot_script']))")
DRY_RUN=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$CONFIG')))['dry_run'])")

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "Start plan-avond voor user=$USER_NAME (dry_run=$DRY_RUN)"

# Voor Autro (syb): lees laatste Atlas-post voor partner_voorstel
PARTNER_VOORSTEL=""
if [[ "$USER_NAME" == "syb" ]]; then
  log "Autro: lees laatste Atlas planning-post..."
  PARTNER_VOORSTEL=$("$DISCORD_BOT" read 20 2>/dev/null | grep -A 20 "PLANNING-SEM Atlas voor $(date -v+1d +%Y-%m-%d)" | head -30 || echo "")
fi

# Run Claude
log "Run Claude..."
PLAN=$(bash "$PROJECT_DIR/scripts/run-claude.sh" "$PARTNER_VOORSTEL" 2>&1)
if [[ $? -ne 0 ]]; then
  log "Claude mislukt: $PLAN"
  "$DISCORD_BOT" send "PLANNING-${USER_NAME^^} FOUT: Claude kon geen plan maken. Log: $LOG"
  exit 1
fi

PLAN_FILE="$LOG_DIR/plan_$TIMESTAMP.json"
echo "$PLAN" > "$PLAN_FILE"
log "Plan geschreven naar $PLAN_FILE"

# Post naar Discord
log "Post voorstel naar Discord..."
bash "$PROJECT_DIR/scripts/post-voorstel.sh" "$PLAN_FILE" | tee -a "$LOG"

# Commit naar dashboard (tenzij dry-run)
if [[ "$DRY_RUN" == "True" || "$DRY_RUN" == "true" ]]; then
  log "DRY RUN: skip commit-planning"
else
  log "Commit blokken naar dashboard..."
  bash "$PROJECT_DIR/scripts/commit-planning.sh" "$PLAN_FILE" | tee -a "$LOG"
fi

log "Klaar"
```

- [ ] **Step 2: Commit**

```bash
chmod +x scripts/plan-avond.sh
git add scripts/plan-avond.sh
git commit -m "feat(agent-bridge): main orchestrator plan-avond"
```

---

## Task 8: Dry-Run Test

**Files:**
- Create: `tests/test-dry-run.sh`

- [ ] **Step 1: Write `tests/test-dry-run.sh`**

```bash
#!/usr/bin/env bash
# End-to-end dry run: fetch → claude → post voorstel, geen commit naar dashboard
set -euo pipefail

CONFIG="$HOME/.config/autronis/agent-bridge.json"
ORIG=$(cat "$CONFIG")
# Toggle dry_run true tijdelijk
python3 -c "
import json, os
p = os.path.expanduser('$CONFIG')
d = json.load(open(p))
d['dry_run'] = True
json.dump(d, open(p, 'w'), indent=2)
"
trap "echo '$ORIG' > '$CONFIG'" EXIT

bash "$( dirname "${BASH_SOURCE[0]}" )/../scripts/plan-avond.sh"
echo "Dry run klaar, check Discord #claude-handoffs voor voorstel"
```

- [ ] **Step 2: Run dry test**

```bash
bash tests/test-dry-run.sh
```

Expected: Discord krijgt een bericht `PLANNING-SEM Atlas voor YYYY-MM-DD`, géén nieuwe entries in dashboard agenda.

- [ ] **Step 3: Commit**

```bash
git add tests/test-dry-run.sh
git commit -m "test(agent-bridge): dry run end-to-end"
```

---

## Task 9: Install + Live Test

- [ ] **Step 1: Kopieer config**

```bash
mkdir -p ~/.config/autronis
cp config/settings.example.json ~/.config/autronis/agent-bridge.json
# Review + pas aan: user=sem, role_name=Atlas, dry_run=false
```

- [ ] **Step 2: Run installer**

```bash
bash scripts/install.sh
```

Expected: `Installed for user=sem at 20:30. Check: launchctl list | grep plan-avond`

- [ ] **Step 3: Verify launchd registered**

```bash
launchctl list | grep plan-avond
```

Expected: één regel met label `com.autronis.plan-avond`, status `-`, exit `0`.

- [ ] **Step 4: Manual kickstart (test de echte flow NU)**

```bash
launchctl kickstart -k gui/$(id -u)/com.autronis.plan-avond
sleep 60
tail -100 logs/plan-avond-error.log
tail -100 logs/plan-avond.log
```

Expected: log bevat "Claude mislukt" OF "Klaar" zonder errors. Dashboard agenda krijgt blokken voor morgen. Discord #claude-handoffs krijgt `PLANNING-SEM Atlas voor YYYY-MM-DD` post.

---

## Task 10: Push naar GitHub + Syb onboarding

- [ ] **Step 1: Maak GitHub repo via gh**

```bash
gh repo create Autronis/agent-bridge --public --source=. --remote=origin --push
```

- [ ] **Step 2: Schrijf README.md met Syb-setup**

README moet bevatten:
1. Wat dit project doet (3 zinnen)
2. Installatie voor Syb: clone repo, `cp config/settings.example.json ~/.config/autronis/agent-bridge.json`, pas `user` naar `syb` en `role_name` naar `Autro`, run `install.sh`
3. Hoe logs te lezen
4. Hoe te uninstallen
5. Troubleshooting (claude binary path verschillen, API key verlopen)

- [ ] **Step 3: Schrijf CLAUDE.md in repo root**

Project context + belangrijkste conventies zodat een future Claude sessie snapt hoe 't werkt.

- [ ] **Step 4: Handoff naar Syb via Discord**

```bash
~/.claude/scripts/discord-bot.sh send "HANDOFF agent-bridge
Van: sem
Prioriteit: normaal

Wat: installeer Autro's planning-bot op jouw Mac.

Context:
- repo: https://github.com/Autronis/agent-bridge
- jouw config: user=syb, role_name=Autro, autro_start_time=20:45

Actie: git clone, kopieer settings.example.json, pas aan (user=syb), run scripts/install.sh. Dan morgen 20:45 zou Autro automatisch plannen."
```

- [ ] **Step 5: Final commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: README + CLAUDE.md voor agent-bridge"
git push
```

---

## Self-Review

**Spec coverage check:**
- ✅ Atlas plant 's avonds voor volgende dag (Task 7 trigger 20:30)
- ✅ Autro idem 20:45
- ✅ Autro leest Atlas-voorstel als `partner_voorstel` (Task 7 stap 1 Discord read)
- ✅ Gebruikt taken + slimme-acties uit dashboard (Task 2 fetch-context)
- ✅ Plaatst blokken in agenda (Task 6 commit-planning via /api/agenda)
- ✅ Discord-post voor transparantie (Task 5)
- ⚠️ Google Calendar push: gebeurt automatisch via `/api/agenda` POST (bestaande gedrag); bevestiging in Task 9 Step 4

**Known risks:**
1. Claude -p kan niet-JSON antwoorden. `run-claude.sh` filtert, bij failure logt en mens moet 's ochtends handmatig ingrijpen.
2. Syb's Mac moet ingelogd zijn om 20:45 (launchd Aqua session); uitdrukkelijk gedocumenteerd in README troubleshooting.
3. Team-taak conflict: als beiden dezelfde team-taak claimen kan er dubbele agenda-plaats komen. Task 2 partner_voorstel moet dit vangen — de eerste poster wint. 2e aanpassing vereist dat Autro de Discord-read goed doet.
4. `claude -p` context size: fetch-context output kan groot worden (honderden taken). Zonodig in Task 2 limiteren tot top-50 per prioriteit.

**Follow-up (na MVP ervaring 1–2 weken):**
- Akkoord-knop (reactie emoji detection) om plan te wijzigen voordat 't in agenda wordt gezet
- Bidirectional overleg (Atlas leest Autro's reactie en past aan, meerdere rondes)
- `/api/agenda/ai-plan` directer aanroepen ipv zelf plannen (werk duplicatie voorkomen)
- Cross-Mac state store voor gestructureerde overleg (Turso tabel `planning_discussions`)

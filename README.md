# Agent Bridge

Atlas (Sem) ↔ Autro (Syb) avondplanning via Claude CLI + Discord + Autronis dashboard.

Elke avond triggert launchd een script dat:
1. Openstaande taken + slimme acties + morgenagenda + uren uit het dashboard leest.
2. `claude -p` aanroept met een planning-prompt → genereert een dagplan als JSON.
3. Een samenvatting post naar Discord `#claude-handoffs` (prefix `PLANNING-SEM` of `PLANNING-SYB`).
4. De tijdsblokken committeert naar `/api/agenda` (dashboard + Google Calendar push).

Atlas draait 20:30 op Sem's Mac, Autro draait 20:45 op Syb's Mac. Autro leest eerst Atlas' post en past zijn eigen plan aan voor team-taken.

## Installatie (per Mac)

```bash
# 1. Clone
cd ~/Autronis/Projects
git clone https://github.com/Autronis/agent-bridge.git
cd agent-bridge

# 2. Config aanmaken (eenmalig)
mkdir -p ~/.config/autronis
cp config/settings.example.json ~/.config/autronis/agent-bridge.json

# 3. Config aanpassen
# Sem: default is al goed (user=sem, role_name=Atlas)
# Syb: zet user=syb, role_name=Autro, partner_role_name=Atlas
$EDITOR ~/.config/autronis/agent-bridge.json

# 4. Check dependencies
which claude    # moet /opt/homebrew/bin/claude zijn
ls ~/.config/autronis/claude-sync.json   # bevat api_key voor dashboard
ls ~/.claude/scripts/discord-bot.sh      # bestaand

# 5. Installeren
bash scripts/install.sh
# → Installed for user=<sem|syb> at <time>.

# 6. Verifiëren
launchctl list | grep plan-avond
# → een regel met com.autronis.plan-avond, exit 0
```

## Handmatige test voor het eerste echte run

```bash
# Dry-run (geen agenda entries, wel Discord post)
bash tests/test-dry-run.sh

# Echte run nu (forceert launchd cron moment)
launchctl kickstart -k gui/$(id -u)/com.autronis.plan-avond
tail -100 logs/plan-avond.log
```

## Hoe werkt het

```
20:30 Atlas (sem's Mac):
  fetch-context.sh   → JSON met taken + slim + agenda + uren
  run-claude.sh      → claude -p → plan JSON
  post-voorstel.sh   → Discord #claude-handoffs
  commit-planning.sh → POST /api/agenda voor elk blok

20:45 Autro (syb's Mac):
  discord-bot.sh read 20 → extract Atlas' PLANNING-SEM post voor morgen
  (alles idem, met partner_voorstel meegegeven aan claude)
```

## Bestanden

| Script | Functie |
|---|---|
| `scripts/plan-avond.sh` | Main orchestrator — door launchd aangeroepen |
| `scripts/fetch-context.sh` | Haalt dashboard data op |
| `scripts/run-claude.sh` | Wrapper om `claude -p` met system prompt templating |
| `scripts/post-voorstel.sh` | Formatteert + post naar Discord |
| `scripts/commit-planning.sh` | POSTet blokken naar `/api/agenda` |
| `scripts/install.sh` / `uninstall.sh` | launchd registratie |
| `prompts/plan-avond.md` | System prompt voor Claude |
| `launchd/com.autronis.plan-avond.plist.template` | plist template (placeholders voor user + tijd) |

## Troubleshooting

**`launchctl list` toont geen plan-avond**
→ `bash scripts/install.sh` opnieuw. Check `~/Library/LaunchAgents/com.autronis.plan-avond.plist`.

**Log toont "Claude mislukt"**
→ Check `logs/plan-avond-error.log` en `logs/plan-avond_<ts>.log`. Meestal: API-key op (verleng via `console.anthropic.com`), of Claude output was geen valide JSON (dan toont de error log de raw output).

**Dry-run werkt, live niet — geen agenda entries in dashboard**
→ Check `dry_run` in config is `false`. Kijk in log of `commit-planning.sh` is aangeroepen en welke HTTP codes het kreeg. Meestal: `api_key` verlopen, of `dashboard_api_key_file` wijst verkeerd.

**Mac stond in slaap om 20:30 — run gemist**
→ launchd's `StartCalendarInterval` slaat gemiste tijden niet in. Oplossing: `launchctl kickstart -k gui/$(id -u)/com.autronis.plan-avond` voor een handmatige run, of zet je Mac niet in slaap voor 21:00.

**Config wijzigen na installatie**
→ Pas `~/.config/autronis/agent-bridge.json` aan, run `bash scripts/uninstall.sh && bash scripts/install.sh` opnieuw om plist te renderen met nieuwe tijd.

## Verwijderen

```bash
bash scripts/uninstall.sh
```

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
launchctl list | grep autronis
# → twee regels: com.autronis.plan-avond + com.autronis.weekrapport, exit 0
```

## Installatie (Windows 11 — Autro / Syb)

Vereisten:
- **Git for Windows** (levert `bash.exe`, `curl`, `python3` via MSYS) — https://git-scm.com/download/win
- **Python 3** — via python.org of MS Store (zorg dat `python3` of `python` in PATH staat)
- **Claude CLI** — `npm i -g @anthropic-ai/claude-code` → levert `claude.cmd` in `%APPDATA%\npm`
- **PowerShell 5.1+** (ingebouwd in Windows 11) of PowerShell 7 (`pwsh`)

```bash
# Vanuit Git Bash:

# 1. Clone
cd ~/Autronis/Projects
git clone https://github.com/Autronis/agent-bridge.git
cd agent-bridge

# 2. Config aanmaken (eenmalig)
mkdir -p ~/.config/autronis
cp config/settings.example.json ~/.config/autronis/agent-bridge.json

# 3. Config aanpassen
# Syb: user=syb, role_name=Autro, partner_role_name=Atlas
# claude_binary: pas aan naar output van `which claude` of `which claude.cmd`,
# bv: /c/Users/syb/AppData/Roaming/npm/claude.cmd
"$EDITOR" ~/.config/autronis/agent-bridge.json

# 4. Check dependencies
which bash        # /usr/bin/bash (git-bash)
which python3 || which python   # beide OK; scripts gebruiken python3
which claude || which claude.cmd
ls ~/.config/autronis/claude-sync.json
ls ~/.claude/scripts/discord-bot.sh

# 5. Installeren — bash delegeert automatisch naar install-windows.ps1
bash scripts/install.sh
# → [OK] Taak 'AutronisPlanAvond' geregistreerd voor user=syb om 20:45.

# 6. Verifiëren (in PowerShell of bash met powershell.exe):
powershell.exe -Command "Get-ScheduledTask -TaskName AutronisPlanAvond"
```

Handmatig triggeren (voor test):

```bash
# Vanuit bash:
powershell.exe -Command "Start-ScheduledTask -TaskName AutronisPlanAvond"
tail -100 logs/plan-avond_*.log
```

## Handmatige test voor het eerste echte run (macOS)

```bash
# Dry-run (geen agenda entries, wel Discord post)
bash tests/test-dry-run.sh

# Echte run nu (forceert launchd cron moment)
launchctl kickstart -k gui/$(id -u)/com.autronis.plan-avond
tail -100 logs/plan-avond.log

# Weekrapport handmatig triggeren:
launchctl kickstart -k gui/$(id -u)/com.autronis.weekrapport
tail -100 logs/weekrapport.log
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

### Wekelijks rapport

```
Zondag 19:00 — Atlas (sem's Mac) + Autro (syb's Mac):
  weekrapport.sh
    ├─ bereken maandag van de lopende week (vandaag − weekday)
    ├─ POST /api/screen-time/samenvatting/periode {datum, type:"week"}
    │   → dashboard genereert AI-samenvatting via Claude + persisteert
    │     in screen_time_samenvattingen
    └─ Discord post naar #weekrapport-sem / #weekrapport-syb
       (splitst automatisch in chunks als >1900 chars)
```

Cached rapport is zichtbaar op `/tijd` (week view) in het dashboard.
Herhaalde calls op dezelfde week overschrijven de bestaande samenvatting
(upsert op gebruiker+datum+type).

## Bestanden

| Script | Functie |
|---|---|
| `scripts/plan-avond.sh` | Main orchestrator — door launchd / Task Scheduler aangeroepen |
| `scripts/weekrapport.sh` | Wekelijkse AI screen-time samenvatting — zondag 19:00 → Discord |
| `scripts/fetch-context.sh` | Haalt dashboard data op |
| `scripts/run-claude.sh` | Wrapper om `claude -p` met system prompt templating |
| `scripts/post-voorstel.sh` | Formatteert + post naar Discord |
| `scripts/commit-planning.sh` | POSTet blokken naar `/api/agenda` |
| `scripts/install.sh` / `uninstall.sh` | Cross-platform installer — detecteert OS, delegeert naar Windows variant waar nodig |
| `scripts/install-windows.ps1` / `uninstall-windows.ps1` | Windows Task Scheduler registratie via PowerShell |
| `prompts/plan-avond.md` | System prompt voor Claude |
| `launchd/com.autronis.plan-avond.plist.template` | macOS plist template (placeholders voor user + tijd) |
| `launchd/com.autronis.weekrapport.plist.template` | macOS plist template voor weekrapport (zondag 19:00) |

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
→ Pas `~/.config/autronis/agent-bridge.json` aan, run `bash scripts/uninstall.sh && bash scripts/install.sh` opnieuw om plist / Scheduled Task te renderen met nieuwe tijd.

### Windows-specifiek

**`install.sh` zegt "Windows gedetecteerd — delegeren naar install-windows.ps1" en doet niks**
→ PowerShell ontbreekt of ExecutionPolicy blokt. Check `powershell.exe -Command $PSVersionTable`. Als blocked: run `powershell.exe -ExecutionPolicy Bypass -File scripts/install-windows.ps1` direct.

**Task bestaat maar draait niet om 20:45**
→ Windows Task Scheduler vereist dat je ingelogd bent (we gebruiken `LogonType Interactive`, matcht macOS Aqua). Check in Task Scheduler GUI: "Last Run Result" en "Last Run Time". Draai handmatig: `powershell.exe -Command "Start-ScheduledTask -TaskName AutronisPlanAvond"`.

**`python3: command not found` in log op Windows**
→ Git-bash ziet de `python` alias niet als `python3`. Oplossing: maak een alias in `~/.bashrc`: `alias python3=python`. Of installeer python via python.org (die zet beide in PATH) en herstart git-bash.

**`claude: command not found` op Windows**
→ `claude_binary` in config wijst naar macOS-pad. Zet het op output van `which claude` (in git-bash), bv. `/c/Users/syb/AppData/Roaming/npm/claude.cmd`.

**`date -v+1d` error op Windows**
→ Zou niet meer moeten — de scripts detecteren BSD vs GNU date automatisch sinds de Windows support update. Als je dit ziet: update naar de laatste main.

## Verwijderen

```bash
bash scripts/uninstall.sh
# Op Windows delegeert dit naar scripts/uninstall-windows.ps1 → Unregister-ScheduledTask.
```

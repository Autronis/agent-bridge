# Agent Bridge — Claude project context

## Wat
Dit project laat Atlas (Claude op Sem's Mac) en Autro (Claude op Syb's Mac) elke avond de dag van morgen plannen: lezen uit het dashboard, overleggen via Discord, committen naar agenda.

## Architectuur
- **launchd** triggert `scripts/plan-avond.sh` elke avond (20:30 Atlas, 20:45 Autro)
- `plan-avond.sh` orkestreert: fetch-context → run-claude → post-voorstel → commit-planning
- Scripts zijn gescheiden zodat elk onafhankelijk testbaar is
- Shared config: `~/.config/autronis/agent-bridge.json` (out of repo)

## Regels voor code
- Gebruik altijd het `read_cfg` env-var pattern voor config parsing — nooit `$VAR` in single-quoted Python source interpoleren (shell injection risk)
- Alle nieuwe scripts zetten `set -euo pipefail` bovenaan
- Bewerkingen die API calls doen moeten stderr gebruiken voor debug en stdout alleen voor eindresultaat (zodat piping werkt)
- Python-oneliners via heredoc (`python3 <<'PY' ... PY`) met env vars voor inputs — NIET string interpolation

## Dependencies (extern, niet in repo)
- `~/.config/autronis/claude-sync.json` — dashboard API key (shared met andere Autronis scripts)
- `~/.claude/scripts/discord-bot.sh` — Discord REST bot (shared)
- `/opt/homebrew/bin/claude` — Claude Code CLI
- Dashboard: `https://dashboard.autronis.nl` API

## Plan + spec
Implementatie-plan: [docs/superpowers/plans/2026-04-19-atlas-autro-planning-bridge.md](docs/superpowers/plans/2026-04-19-atlas-autro-planning-bridge.md)

## Bekende beperkingen (MVP)
- launchd `LimitLoadToSessionType=Aqua` + `StartCalendarInterval` → als Mac slaapt/uit om 20:30, wordt de run gemist (geen inhaal). Kickstart handmatig om in te halen.
- Team-taak conflict detection is best-effort: Autro leest Atlas' Discord post, maar als Sem na 20:45 nog edit, wordt dat niet meer gezien.
- Commit-planning.sh faalt stil bij individuele blokken (exit 0 met fail-count) — check log voor details.
- Geen bidirectional overleg (één ronde, geen Atlas-reageert-op-Autro). Komt later als nodig.

## Niet doen
- Geen `claude --channels discord-plugin` approach — die daemon is broken (zat vast op stdin).
- Geen cross-Mac Turso-table voor coordinatie — Discord posts zijn de state.
- Geen dashboard writes anders dan `/api/agenda` POST — andere writes breken bestaande flows.

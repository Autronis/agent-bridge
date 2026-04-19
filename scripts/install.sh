#!/usr/bin/env bash
# install.sh — cross-platform installer.
#  * macOS  → launchd (StartCalendarInterval) via .plist template
#  * Windows (git-bash / MSYS / Cygwin) → delegates to install-windows.ps1
#    (Windows Task Scheduler via PowerShell)
#  * Linux  → not yet supported (cron wrapper welkom als PR)
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG_PATH="$HOME/.config/autronis/agent-bridge.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config niet gevonden. Kopieer config/settings.example.json naar $CONFIG_PATH en pas aan."
  exit 1
fi

case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*)
    echo "Windows gedetecteerd ($OSTYPE) — delegeren naar install-windows.ps1"
    # Try powershell.exe first (Windows PowerShell 5.x, altijd aanwezig),
    # fallback naar pwsh (PowerShell 7+ cross-platform).
    PS_BIN=""
    if command -v powershell.exe >/dev/null 2>&1; then
      PS_BIN="powershell.exe"
    elif command -v pwsh >/dev/null 2>&1; then
      PS_BIN="pwsh"
    else
      echo "install: kan powershell.exe noch pwsh vinden in PATH" >&2
      exit 1
    fi
    # Convert POSIX path to Windows path for PowerShell arg.
    WIN_SCRIPT="$PROJECT_DIR/scripts/install-windows.ps1"
    if command -v cygpath >/dev/null 2>&1; then
      WIN_SCRIPT=$(cygpath -w "$WIN_SCRIPT")
    fi
    exec "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$WIN_SCRIPT"
    ;;
  linux*)
    echo "Linux nog niet ondersteund (cron wrapper welkom als PR)"
    exit 1
    ;;
  darwin*|"")
    # macOS path — gaat door naar launchd hieronder.
    # (OSTYPE kan leeg zijn in sommige shells; behandel als darwin als platform bash 'darwin' terug geeft.)
    if [[ "${OSTYPE:-}" == "" ]] && [[ "$(uname -s)" != "Darwin" ]]; then
      echo "install: onbekende OS (uname=$(uname -s)); alleen macOS/Windows ondersteund"
      exit 1
    fi
    ;;
  *)
    echo "install: onbekende OS: $OSTYPE; alleen macOS/Windows ondersteund"
    exit 1
    ;;
esac

# -------- macOS / launchd installation --------

read_cfg() {
  CONFIG_PATH="$CONFIG_PATH" python3 -c '
import json, os, sys
with open(os.environ["CONFIG_PATH"]) as f:
    print(json.load(f)[sys.argv[1]])
' "$1"
}

USER_NAME=$(read_cfg user)
ATLAS_TIME=$(read_cfg atlas_start_time)
AUTRO_TIME=$(read_cfg autro_start_time)

case "$USER_NAME" in
  sem) TIME="$ATLAS_TIME" ;;
  syb) TIME="$AUTRO_TIME" ;;
  *) echo "Fout: 'user' in $CONFIG_PATH moet 'sem' of 'syb' zijn (kreeg: '$USER_NAME')" >&2; exit 1 ;;
esac
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

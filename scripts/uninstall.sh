#!/usr/bin/env bash
# uninstall.sh — cross-platform uninstaller.
#  * macOS   → unload + rm plist
#  * Windows → delegates to uninstall-windows.ps1 (Unregister-ScheduledTask)
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*)
    echo "Windows gedetecteerd ($OSTYPE) — delegeren naar uninstall-windows.ps1"
    PS_BIN=""
    if command -v powershell.exe >/dev/null 2>&1; then
      PS_BIN="powershell.exe"
    elif command -v pwsh >/dev/null 2>&1; then
      PS_BIN="pwsh"
    else
      echo "uninstall: kan powershell.exe noch pwsh vinden in PATH" >&2
      exit 1
    fi
    WIN_SCRIPT="$PROJECT_DIR/scripts/uninstall-windows.ps1"
    if command -v cygpath >/dev/null 2>&1; then
      WIN_SCRIPT=$(cygpath -w "$WIN_SCRIPT")
    fi
    exec "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$WIN_SCRIPT"
    ;;
esac

# macOS path — remove both plists if present.
for LABEL in com.autronis.plan-avond com.autronis.weekrapport; do
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm "$PLIST"
    echo "Uninstalled $LABEL."
  fi
done
echo "Klaar. Check: launchctl list | grep autronis  (mag leeg zijn)"

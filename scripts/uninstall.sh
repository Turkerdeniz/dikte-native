#!/bin/zsh
set -euo pipefail

APP="/Applications/Dikte.app"
SUPPORT="$HOME/Library/Application Support/Dikte Native"

osascript -e 'tell application id "com.turkerdenizer.dikte.native" to quit' 2>/dev/null || true
if [[ -e "$APP" ]]; then mv "$APP" "$HOME/.Trash/Dikte-$(date +%Y%m%d-%H%M%S).app"; fi
if [[ -e "$SUPPORT" ]]; then mv "$SUPPORT" "$HOME/.Trash/Dikte-Native-Data-$(date +%Y%m%d-%H%M%S)"; fi
print "Dikte and its Application Support data were moved to Trash. Disable the native login item before uninstalling if it was enabled."

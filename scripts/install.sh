#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_ZIP="$ROOT_DIR/build/Dikte.app.zip"
TARGET_APP="/Applications/Dikte.app"
RUNNING_PATTERN="^/Applications/Dikte.app/Contents/MacOS/DikteNative$"
TEMP_DIR="$(mktemp -d /private/tmp/dikte-native-install.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

[[ -f "$SOURCE_ZIP" ]] || "$ROOT_DIR/scripts/build.sh"
ditto -x -k "$SOURCE_ZIP" "$TEMP_DIR"
SOURCE_APP="$TEMP_DIR/Dikte.app"
codesign --verify --deep --strict "$SOURCE_APP"

if pgrep -f "$RUNNING_PATTERN" >/dev/null; then
  pkill -TERM -f "$RUNNING_PATTERN"
  for _ in {1..20}; do
    pgrep -f "$RUNNING_PATTERN" >/dev/null || break
    sleep 0.1
  done
  if pgrep -f "$RUNNING_PATTERN" >/dev/null; then pkill -KILL -f "$RUNNING_PATTERN"; fi
fi

if [[ -e "$TARGET_APP" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TARGET_APP" 2>/dev/null || true
  BACKUP="/private/tmp/Dikte-previous-$(date +%Y%m%d-%H%M%S).app.disabled"
  mv "$TARGET_APP" "$BACKUP"
  print "Previous app moved temporarily to: $BACKUP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
open "$TARGET_APP"
print "Installed: $TARGET_APP"

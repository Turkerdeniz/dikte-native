#!/bin/zsh
set -euo pipefail

APP="/Applications/Dikte.app"
BUNDLE_ID="com.turkerdenizer.dikte.native"
SUPPORT="$HOME/Library/Application Support/Dikte Native"
PREFERENCES="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CACHES="$HOME/Library/Caches/$BUNDLE_ID"
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DATA_MODE="keep"
DRY_RUN=false
SCRIPT_NAME="${0:t}"

usage() {
  print "Usage: $SCRIPT_NAME [--keep-data|--remove-data] [--dry-run]"
  print ""
  print "  --keep-data    Preserve model, history and settings (default)."
  print "  --remove-data  Move local Dikte data to Trash. Nothing is permanently deleted."
  print "  --dry-run      Show the exact actions without changing anything."
}

for argument in "$@"; do
  case "$argument" in
    --keep-data) DATA_MODE="keep" ;;
    --remove-data) DATA_MODE="remove" ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $argument"; usage >&2; exit 2 ;;
  esac
done

trash_destination() {
  local source="$1"
  local name="${source:t}"
  local stamp="$(date +%Y%m%d-%H%M%S)"
  local stem="$name"
  local extension=""
  if [[ "$name" == *.app || "$name" == *.plist || "$name" == *.savedState ]]; then
    stem="${name%.*}"
    extension=".${name##*.}"
  fi
  local destination="$HOME/.Trash/$stem-$stamp$extension"
  local suffix=1
  while [[ -e "$destination" ]]; do
    destination="$HOME/.Trash/$stem-$stamp-$suffix$extension"
    (( suffix += 1 ))
  done
  print -r -- "$destination"
}

move_to_trash() {
  local source="$1"
  local label="$2"
  [[ -e "$source" ]] || { print "Atlandı ($label bulunamadı): $source"; return 0; }
  local destination="$(trash_destination "$source")"
  if $DRY_RUN; then
    print "[dry-run] Çöp’e taşınacak ($label): $source -> $destination"
  else
    mv "$source" "$destination"
    print "Çöp’e taşındı ($label): $destination"
  fi
}

if [[ -e "$APP" ]]; then
  ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || {
    print -u2 "Güvenlik nedeniyle işlem durduruldu: $APP bundle kimliği '$ACTUAL_BUNDLE_ID'."
    exit 1
  }
fi

if $DRY_RUN; then
  print "[dry-run] Dikte süreci güvenli biçimde kapatılacak."
  [[ -x "$APP/Contents/MacOS/DikteNative" ]] && \
    print "[dry-run] Native login item kaydı bakım moduyla kaldırılacak."
  [[ -e "$APP" ]] && print "[dry-run] LaunchServices kaydı kaldırılacak: $APP"
else
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  RUNNING_PATTERN="^$APP/Contents/MacOS/DikteNative$"
  for _ in {1..20}; do
    pgrep -f "$RUNNING_PATTERN" >/dev/null || break
    sleep 0.1
  done
  if pgrep -f "$RUNNING_PATTERN" >/dev/null; then
    pkill -TERM -f "$RUNNING_PATTERN"
    for _ in {1..20}; do
      pgrep -f "$RUNNING_PATTERN" >/dev/null || break
      sleep 0.1
    done
  fi
  pgrep -f "$RUNNING_PATTERN" >/dev/null && {
    print -u2 "Dikte güvenli biçimde kapatılamadı; hiçbir dosya taşınmadı."
    exit 1
  }

  if [[ -x "$APP/Contents/MacOS/DikteNative" ]]; then
    "$APP/Contents/MacOS/DikteNative" --maintenance-unregister-login-item
  else
    print "Atlandı (uygulama bulunamadı): native login item bakım modu"
  fi
  [[ -e "$APP" ]] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
fi

move_to_trash "$APP" "uygulama"

if [[ "$DATA_MODE" == "remove" ]]; then
  move_to_trash "$SUPPORT" "Application Support"
  move_to_trash "$PREFERENCES" "ayarlar"
  move_to_trash "$CACHES" "önbellek"
  move_to_trash "$SAVED_STATE" "kaydedilmiş pencere durumu"
  if ! $DRY_RUN; then defaults delete "$BUNDLE_ID" 2>/dev/null || true; fi
else
  print "Kullanıcı verileri korundu: $SUPPORT"
  print "Ayarlar korundu: $PREFERENCES"
fi

if $DRY_RUN; then
  print "Dry-run tamamlandı; hiçbir değişiklik yapılmadı."
else
  print "Dikte kaldırma işlemi tamamlandı. Taşınan öğeler Çöp’ten geri alınabilir."
fi

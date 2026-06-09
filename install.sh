#!/usr/bin/env bash
#
# flac2watch installer
#   - installs the `flac2watch` CLI to ~/.local/bin (+ symlink on PATH)
#   - builds the FLAC2Watch drag & drop app into ~/Applications
#   - installs & loads the auto-sync LaunchAgent
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$REPO/bin/flac2watch"
APP_SRC="$REPO/app/FLAC2Watch.applescript"
PLIST_SRC="$REPO/launchd/com.lordhayne.flac2watch.plist"

BIN_DIR="$HOME/.local/bin"
BIN_DST="$BIN_DIR/flac2watch"
APP_DIR="$HOME/Applications"
APP_DST="$APP_DIR/FLAC2Watch.app"
LIBRARY="$HOME/Music/WatchSync"
LOG="$HOME/.cache/flac2watch/flac2watch.log"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_DST="$AGENT_DIR/com.lordhayne.flac2watch.plist"

G=$'\033[32m'; B=$'\033[1m'; Y=$'\033[33m'; X=$'\033[0m'
ok() { printf "${G}✓${X} %s\n" "$*"; }

echo "${B}flac2watch — Installation${X}"

# 1. Requirements -----------------------------------------------------------
miss=0
for t in ffmpeg adb; do
  if ! command -v "$t" >/dev/null 2>&1; then
    printf "${Y}!${X} %s fehlt.\n" "$t"; miss=1
  fi
done
if [ "$miss" = 1 ]; then
  echo "  Bitte installieren:  brew install ffmpeg && brew install --cask android-platform-tools"
  exit 1
fi
ok "ffmpeg & adb vorhanden"

# 2. CLI --------------------------------------------------------------------
mkdir -p "$BIN_DIR" "$LIBRARY" "$(dirname "$LOG")"
install -m 0755 "$BIN_SRC" "$BIN_DST"
ok "CLI installiert: $BIN_DST"
# put on PATH if Homebrew bin is writable (typical on this user's Mac)
if [ -w /opt/homebrew/bin ]; then
  ln -sf "$BIN_DST" /opt/homebrew/bin/flac2watch
  ok "Symlink: /opt/homebrew/bin/flac2watch (im PATH)"
fi

# 3. Drag & drop app --------------------------------------------------------
mkdir -p "$APP_DIR"
rm -rf "$APP_DST"
osacompile -o "$APP_DST" "$APP_SRC"
ok "App gebaut: $APP_DST"

# 4. Auto-sync LaunchAgent --------------------------------------------------
mkdir -p "$AGENT_DIR"
sed -e "s#__BIN__#$BIN_DST#g" \
    -e "s#__LIBRARY__#$LIBRARY#g" \
    -e "s#__LOG__#$LOG#g" \
    "$PLIST_SRC" >"$AGENT_DST"
launchctl unload "$AGENT_DST" >/dev/null 2>&1 || true
launchctl load "$AGENT_DST"
ok "Auto-Sync-Agent geladen (synct bei Ordner-Änderung + alle 5 Min)"

echo ""
echo "${B}Fertig!${X}  Nächste Schritte:"
echo "  1. Uhr einmalig koppeln:   ${B}flac2watch pair${X}"
echo "  2. Musik in den Ordner legen (oder auf die App ziehen):"
echo "     ${B}$LIBRARY${X}"
echo "  → Der Rest passiert automatisch, sobald die Uhr im WLAN ist."

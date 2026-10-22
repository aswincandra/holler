#!/bin/zsh
# Build "Bardi Speak.app" (app + desktop widget) with Xcode, then install it to
# /Applications and relaunch it if it was running. Pass --no-install to only build.
# The team comes from the Apple ID in Xcode › Settings › Accounts (or set DEVELOPMENT_TEAM).
set -euo pipefail
cd "$(dirname "$0")"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -I -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
teams = d.get("IDEProvisioningTeamByIdentifier") or d.get("IDEProvisioningTeams") or {}
ids = [t.get("teamID") for v in teams.values() for t in (v if isinstance(v, list) else [v]) if isinstance(t, dict)]
print(next((i for i in ids if i), ""))' || true)
fi
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  # The team ID is the OU field of the "Apple Development" certificate.
  DEVELOPMENT_TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}' || true)
fi
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "No Apple ID team found. Add your Apple ID in Xcode › Settings › Accounts, or set DEVELOPMENT_TEAM."
  exit 1
fi
export DEVELOPMENT_TEAM
echo "Team: $DEVELOPMENT_TEAM"

scripts/gen_bridge.sh
xcodegen generate --quiet

LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project BardiSpeak.xcodeproj -scheme BardiSpeak -configuration Release \
     -derivedDataPath build/DerivedData -allowProvisioningUpdates \
     DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build > "$LOG" 2>&1; then
  grep -E "error:|warning: .*(signing|provision)" "$LOG" | sort -u | head -30
  echo "Build failed. Full log: $LOG"
  exit 1
fi
APP="build/DerivedData/Build/Products/Release/Bardi Speak.app"
echo "Built $APP"

if (( INSTALL )); then
  DEST="/Applications/Bardi Speak.app"
  WAS_RUNNING=0
  if pgrep -f "Bardi Speak.app/Contents/MacOS/BardiSpeak" >/dev/null; then
    WAS_RUNNING=1
    osascript -e 'quit app id "id.aswin.bardispeak"' 2>/dev/null || true
    sleep 1
    pkill -f "Bardi Speak.app/Contents/MacOS/BardiSpeak" 2>/dev/null || true
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Register the widget from the installed copy, not the build folder.
  pluginkit -a "$DEST/Contents/PlugIns/BardiSpeakWidget.appex" 2>/dev/null || true
  echo "Installed $DEST"
  if (( WAS_RUNNING )); then
    open "$DEST" --args --background  # stay in the menu bar; don't pop up the window
    echo "Relaunched"
  fi
fi

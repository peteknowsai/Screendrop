#!/bin/sh
# Builds our own Release Screendrop, signed with the team in the project
# file, into build/. With --install it replaces /Applications/Screendrop.app.
set -eu
cd "$(dirname "$0")/.."

xcodebuild build -project Screendrop.xcodeproj -scheme Screendrop -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -quiet
app=build/Build/Products/Release/Screendrop.app
echo "Built $app"

[ "${1:-}" = "--install" ] || exit 0

osascript -e 'quit app "Screendrop"' || true
sleep 1
if [ -d /Applications/Screendrop.app ]; then
  mv /Applications/Screendrop.app "$HOME/.Trash/Screendrop-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$app" /Applications/Screendrop.app
echo "Open Screendrop once; macOS will ask again for Screen Recording, Camera, Microphone and Input Monitoring, and once for the Keychain upload token."

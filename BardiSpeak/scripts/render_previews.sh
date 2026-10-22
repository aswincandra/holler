#!/bin/zsh
# Render the README preview images from the app's real SwiftUI views (sample data only).
# Output: docs/images/*.png at the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/gen_bridge.sh
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-} xcodegen generate --quiet
xcodebuild -project BardiSpeak.xcodeproj -target BardiSpeakPreviews -configuration Release \
  SYMROOT="$PWD/build/previews" build > build/previews.log 2>&1 \
  || { grep -E "error:" build/previews.log | sort -u | head -20; echo "Build failed: build/previews.log"; exit 1; }
build/previews/Release/BardiSpeakPreviews ../docs/images

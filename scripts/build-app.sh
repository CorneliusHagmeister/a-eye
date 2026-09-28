#!/bin/bash
# Build GazeVoice.app into dist/. Ad-hoc signed with a fixed designated requirement
# so macOS privacy grants (Accessibility, Camera, Mic) survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/GazeVoice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GazeVoice "$APP/Contents/MacOS/GazeVoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.gazevoice.app \
  -r='designated => identifier "dev.gazevoice.app"' "$APP"
echo "built $APP"

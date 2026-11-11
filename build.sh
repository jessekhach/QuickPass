#!/bin/bash
# Development build: compiles, installs to ~/Applications and relaunches.
# Signed with your Apple Development certificate so the Accessibility permission survives rebuilds.
# For a distributable DMG use scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project QuickPass.xcodeproj -scheme QuickPass -configuration Release \
  -destination generic/platform=macOS -derivedDataPath build/DerivedData -quiet build
APP=build/DerivedData/Build/Products/Release/QuickPass.app

pkill -x QuickPass || true
mkdir -p ~/Applications
rm -rf ~/Applications/QuickPass.app
cp -R "$APP" ~/Applications/
open ~/Applications/QuickPass.app

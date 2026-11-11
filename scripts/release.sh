#!/bin/bash
# Builds a signed, notarized QuickPass DMG in build/release and adds it to appcast.xml, the feed
# the app checks for updates. Commit and push appcast.xml after uploading the DMG to the release.
#
# Needs create-dmg (brew install create-dmg), a "Developer ID Application" certificate and the
# Sparkle update key (created once with Sparkle's generate_keys) in your keychain, plus an
# App Store Connect API key:
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#   ASC_KEY_ID     the key's ID
#   ASC_ISSUER_ID  your team's issuer ID
#
# The app is notarized and stapled before it goes into the DMG, then the DMG gets the same, so
# both open without a Gatekeeper warning even offline.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_PATH:?Set ASC_KEY_PATH to your App Store Connect .p8 key}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
OUT=build/release
APP="$OUT/QuickPass.app"
DMG="$OUT/QuickPass-$VERSION.dmg"
DERIVED=build/DerivedData
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait)

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building QuickPass $VERSION"
xcodegen generate --quiet
xcodebuild archive -project QuickPass.xcodeproj -scheme QuickPass -configuration Release \
  -destination generic/platform=macOS -derivedDataPath "$DERIVED" -archivePath "$OUT/QuickPass.xcarchive" \
  "${AUTH[@]}" -quiet
xcodebuild -exportArchive -archivePath "$OUT/QuickPass.xcarchive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$OUT" "${AUTH[@]}" -quiet

echo "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/QuickPass.zip"
xcrun notarytool submit "$OUT/QuickPass.zip" "${NOTARY[@]}"
xcrun stapler staple "$APP"

echo "Building the DMG"
# The window layout matches the arrow drawn in Resources/dmg-background.tiff
# (scripts/make-dmg-background.swift). create-dmg arranges it through Finder.
mkdir "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/"
create-dmg --volname "QuickPass" --background Resources/dmg-background.tiff \
  --window-pos 200 120 --window-size 660 400 --icon-size 128 \
  --icon "QuickPass.app" 180 190 --hide-extension "QuickPass.app" --app-drop-link 480 190 \
  --no-internet-enable "$DMG" "$OUT/dmg/" > /dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "Notarizing the DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}"
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "Updating appcast.xml"
mkdir "$OUT/updates"
cp "$DMG" "$OUT/updates/"
[ -f appcast.xml ] && cp appcast.xml "$OUT/updates/"
"$SPARKLE_BIN/generate_appcast" "$OUT/updates" \
  --download-url-prefix "https://github.com/jessekhach/QuickPass/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/jessekhach/QuickPass/releases" \
  --link "https://github.com/jessekhach/QuickPass"
cp "$OUT/updates/appcast.xml" appcast.xml

echo "Done: $DMG"
shasum -a 256 "$DMG"

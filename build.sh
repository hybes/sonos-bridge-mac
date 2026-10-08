#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
OUTPUT_DIR="$SOURCE_DIR/dist"
BUILD_DIR="$SOURCE_DIR/build"
MODE="${1:-local}"
SIGN_OPTIONS=(--force --sign -)
case "$MODE" in
  local) ;;
  release)
    : "${SONOS_BRIDGE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
    : "${SONOS_BRIDGE_NOTARY_PROFILE:?Set a notarytool keychain profile}"
    SIGN_OPTIONS=(--force --timestamp --options runtime --sign "$SONOS_BRIDGE_SIGNING_IDENTITY")
    ;;
  *) printf 'Usage: bash build.sh [local|release]\n' >&2; exit 1 ;;
esac
STAGE_DIR="$(mktemp -d /private/tmp/sonos-bridge.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP="$STAGE_DIR/Sonos Bridge.app"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$APP/Contents/MacOS"
xcrun swiftc -g -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
  "$SOURCE_DIR/Models.swift" "$SOURCE_DIR/Tests/main.swift" -o "$BUILD_DIR/ModelTests"
"$BUILD_DIR/ModelTests"
xcrun swiftc -O -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework MediaPlayer -framework ServiceManagement \
  "$SOURCE_DIR/Models.swift" "$SOURCE_DIR/SonosClient.swift" "$SOURCE_DIR/main.swift" \
  -o "$APP/Contents/MacOS/SonosBridge"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$MODE" == release ]]; then
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGE_DIR/notary.zip"
  xcrun notarytool submit "$STAGE_DIR/notary.zip" --keychain-profile "$SONOS_BRIDGE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute "$APP"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP_NAME="SonosBridge-$VERSION-macOS-arm64.zip"
# Package before Documents' file provider can attach Finder metadata to the app.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT_DIR/$ZIP_NAME"
ditto --norsrc --noextattr "$APP" "$OUTPUT_DIR/Sonos Bridge.app"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ZIP_NAME" > SHA256SUMS)
printf 'Built %s\n' "$OUTPUT_DIR/$ZIP_NAME"

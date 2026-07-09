#!/bin/bash
# Builds Dbosk.app from the SPM executable.
#
# Usage:
#   Scripts/make-app.sh            # release build, ad-hoc signed -> dist/Dbosk.app
#   Scripts/make-app.sh --dmg      # also produce dist/Dbosk.dmg
#
# Environment:
#   DBOSK_SIGN_IDENTITY   Developer ID Application identity for real signing
#                         (default: ad-hoc "-"). With a real identity the
#                         binary is signed with hardened runtime + timestamp,
#                         ready for `xcrun notarytool submit`.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Dbosk"
BUNDLE_ID="dev.dbosk.app"
VERSION="0.1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"
IDENTITY="${DBOSK_SIGN_IDENTITY:--}"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> Signing (identity: $IDENTITY)"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP"
else
    # Hardened runtime + timestamp: required for notarization.
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
fi
codesign --verify --verbose=2 "$APP"

if [[ "${1:-}" == "--dmg" ]]; then
    DMG="$DIST/$APP_NAME.dmg"
    echo "==> Creating $DMG"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
    echo "    To notarize: xcrun notarytool submit $DMG --keychain-profile <profile> --wait"
    echo "    Then staple:  xcrun stapler staple $DMG"
fi

echo "==> Done: $APP"

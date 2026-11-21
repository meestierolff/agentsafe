#!/bin/bash
# Turns dist/AgentSafe.app into a notarized dist/AgentSafe.dmg that opens without warnings.
#
# One-time setup, in your own terminal (never paste the password into a chat):
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. Create an app-specific password at https://account.apple.com (Sign-In and Security)
#   3. xcrun notarytool store-credentials agentsafe-notary \
#        --apple-id "you@example.com" --team-id "YOURTEAMID"
#      (it asks for the app-specific password and keeps it in your keychain)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-agentsafe-notary}"
APP="dist/AgentSafe.app"
DMG="dist/AgentSafe.dmg"

codesign -dv "$APP" 2>&1 | grep -q "Developer ID Application" || {
  echo "The app is not signed with a Developer ID certificate. Create one (step 1 above) and rebuild." >&2
  exit 1
}

# Re-sign with a secure timestamp, which notarization requires.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
codesign --force --options runtime --timestamp \
  --identifier live.agentsafe.cli --sign "$IDENTITY" "$APP/Contents/Helpers/agentsafe"
codesign --force --options runtime --timestamp \
  --entitlements Resources/AgentSafe.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AgentSafe" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready to ship: $DMG"

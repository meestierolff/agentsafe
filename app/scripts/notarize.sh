#!/bin/bash
# Turns <folder>/AgentSafe.app into a notarized <folder>/AgentSafe.dmg that opens without
# warnings on any Mac. The folder is "release" unless OUT_DIR says otherwise.
#
# One-time setup, in your own terminal (never paste the password into a chat):
#   1. Create an app-specific password at https://account.apple.com (Sign-In and Security)
#   2. xcrun notarytool store-credentials agentsafe-notary \
#        --apple-id "you@example.com" --team-id "YOURTEAMID"
#      (it asks for the app-specific password and keeps it in your keychain)
#
#   ./scripts/notarize.sh              sign, package, send to Apple, staple
#   REHEARSE=1 ./scripts/notarize.sh   everything except sending to Apple
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-agentsafe-notary}"
OUT_DIR="${OUT_DIR:-release}"
APP="$OUT_DIR/AgentSafe.app"
DMG="$OUT_DIR/AgentSafe.dmg"

[ -d "$APP" ] || { echo "No app at $APP. Build it first: RELEASE=1 ./scripts/build-app.sh" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in your keychain." >&2; exit 1; }

# Sign again with a secure timestamp, which notarization requires. Inner code first.
codesign --force --options runtime --timestamp \
  --identifier live.agentsafe.cli --sign "$IDENTITY" "$APP/Contents/Helpers/agentsafe"
codesign --force --options runtime --timestamp \
  --entitlements Resources/AgentSafe.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Confirm what is about to ship: the right signer, a timestamp, the sandbox, no network.
DETAILS="$(codesign -dvv "$APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
case "$DETAILS" in *"Authority=Developer ID Application"*) ;; *) echo "The app is not signed with Developer ID." >&2; exit 1 ;; esac
case "$DETAILS" in *"Timestamp="*) ;; *) echo "The signature has no secure timestamp." >&2; exit 1 ;; esac
case "$ENTITLEMENTS" in *"com.apple.security.app-sandbox"*) ;; *) echo "The app is not sandboxed." >&2; exit 1 ;; esac
case "$ENTITLEMENTS" in *"com.apple.security.network"*) echo "The app has a network entitlement. It must not." >&2; exit 1 ;; esac

[ ! -e "$DMG" ] || rm "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "AgentSafe" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG"

if [ "${REHEARSE:-}" = "1" ]; then
  echo "Rehearsal complete: $DMG is signed and packaged, and was NOT sent to Apple."
  exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready to ship: $DMG"

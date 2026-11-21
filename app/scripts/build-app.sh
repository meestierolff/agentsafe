#!/bin/bash
# Builds AgentSafe.app, signed and sandboxed.
#   ./scripts/build-app.sh             for your own Mac, into dist/
#   RELEASE=1 ./scripts/build-app.sh   for distribution, into release/, signed with Developer ID
#   SIGN_IDENTITY="-" ./scripts/...    ad-hoc signature (runs on this Mac only)
#
# The two kinds of build go to different folders on purpose: making a release must never
# replace the copy of the app you are running.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
if [ "${RELEASE:-}" = "1" ]; then OUT_DIR="${OUT_DIR:-release}"; else OUT_DIR="${OUT_DIR:-dist}"; fi
APP="$OUT_DIR/AgentSafe.app"

# One binary each for Apple silicon and Intel Macs: the app, and the `agentsafe` command.
swift build -c release --product AgentSafe --arch arm64 --arch x86_64
swift build -c release --product agentsafe-cli --arch arm64 --arch x86_64
BINARY=""
HELPER=""
for folder in .build/out/Products/Release .build/apple/Products/Release; do
  [ -f "$folder/AgentSafe" ] && BINARY="$folder/AgentSafe"
  [ -f "$folder/agentsafe-cli" ] && HELPER="$folder/agentsafe-cli"
  [ -n "$BINARY" ] && [ -n "$HELPER" ] && break
done
[ -n "$BINARY" ] && [ -n "$HELPER" ] || { echo "Could not find the built binaries." >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BINARY" "$APP/Contents/MacOS/AgentSafe"
cp "$HELPER" "$APP/Contents/Helpers/agentsafe"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: one 1024px PNG becomes every size macOS wants.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A release is signed with Developer ID. Everyday builds keep using the development
# certificate, so the app you run keeps one stable identity.
find_identity() { security find-identity -v -p codesigning | awk -F'"' -v kind="$1" '$2 ~ kind {print $2; exit}'; }
if [ -z "${SIGN_IDENTITY:-}" ]; then
  if [ "${RELEASE:-}" = "1" ]; then
    SIGN_IDENTITY="$(find_identity "^Developer ID Application")"
    [ -n "$SIGN_IDENTITY" ] || { echo "No Developer ID Application certificate in your keychain." >&2; exit 1; }
  else
    SIGN_IDENTITY="$(find_identity "^Apple Development")"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(find_identity "^Developer ID Application")"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
  fi
fi

# The command-line helper is signed on its own, without the sandbox: it is started from a
# terminal, and a sandboxed program could not start the user's commands. Inner code first.
codesign --force --options runtime --timestamp=none \
  --identifier live.agentsafe.cli --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/agentsafe"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/AgentSafe.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
case "$SIGN_IDENTITY" in
  "Developer ID Application"*) echo "Signed with Developer ID. Next: OUT_DIR=$OUT_DIR ./scripts/notarize.sh" ;;
  "-") echo "Ad-hoc signed: runs on this Mac only." ;;
  *) echo "Signed with a development certificate: fine on your own Macs, not for distribution." ;;
esac

#!/bin/bash
# Builds dist/AgentSafe.app, signed and sandboxed.
#   ./scripts/build-app.sh            release build, signed with the best identity found
#   SIGN_IDENTITY="-" ./scripts/...   ad-hoc signature (runs on this Mac only)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
APP="dist/AgentSafe.app"

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

# Prefer a Developer ID certificate (needed to distribute), then a development one.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
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
  "Developer ID Application"*) echo "Signed for distribution. Next: ./scripts/notarize.sh" ;;
  "-") echo "Ad-hoc signed: runs on this Mac only." ;;
  *) echo "Signed with a development certificate: fine on your own Macs, not for distribution." ;;
esac

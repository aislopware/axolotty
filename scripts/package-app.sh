#!/usr/bin/env bash
# Builds dist/Axolotty.app: the app, the server (axolottyd), the PTY holder
# (axolotty-ptyd) and the CLI (axolotty) side by side in Contents/MacOS, the
# server's LaunchAgent (registered by the app through SMAppService), and the
# icon drawn from the mark. Signed ad hoc unless SIGN_IDENTITY is set.
#
# Usage: scripts/package-app.sh            (release)
#        CONFIG=debug scripts/package-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="dev.axolotty.app"

cd "$ROOT"
swift build -c "$CONFIG" --product AxolottyDev
swift build -c "$CONFIG" --product axolottyd
swift build -c "$CONFIG" --product axolotty-ptyd
swift build -c "$CONFIG" --product axolotty
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$OUT/Axolotty.app"
STAGE="$(mktemp -d)"
trap '/bin/rm -rf "$STAGE"' EXIT
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

cp "$BIN/AxolottyDev" "$APP/Contents/MacOS/Axolotty"
for b in axolottyd axolotty-ptyd axolotty; do cp "$BIN/$b" "$APP/Contents/MacOS/$b"; done
# The UI's SwiftPM resource bundle (the terminal font), where Bundle.module looks in an app.
cp -R "$BIN/Axolotty_AxMacUI.bundle" "$APP/Contents/Resources/"

"$BIN/AxolottyDev" --write-iconset "$STAGE/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Axolotty</string>
  <key>CFBundleDisplayName</key><string>Axolotty</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Axolotty</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Axolotty</string>
</dict>
</plist>
PLIST

# launchd keeps the server alive and starts it at login; it outlives the app.
cat > "$APP/Contents/Library/LaunchAgents/dev.axolotty.server.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.axolotty.server</string>
  <key>BundleProgram</key><string>Contents/MacOS/axolottyd</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

# Inside out: helpers first, then the bundle.
for b in axolottyd axolotty-ptyd axolotty; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/$b"
done
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP ($VERSION, $BUILD, $CONFIG)"

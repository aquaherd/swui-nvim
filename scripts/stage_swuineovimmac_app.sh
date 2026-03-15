#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${1:-debug}"

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

swift build -c "$CONFIGURATION" --product SWUINeovimMac

BUILD_DIR="$(swift build -c "$CONFIGURATION" --product SWUINeovimMac --show-bin-path)"
BIN_PATH="$BUILD_DIR/SWUINeovimMac"
APP_ROOT="$BUILD_DIR/SWUINeovimMac.app"
INFO_PLIST="$APP_ROOT/Contents/Info.plist"
ICONSET_SOURCE="$ROOT_DIR/SWUINeovim/Resources/Assets.xcassets/AppIcon.appiconset"
ICON_NAME="AppIcon"
ICON_FILE="$APP_ROOT/Contents/Resources/$ICON_NAME.icns"
DSYM_PATH="$BUILD_DIR/SWUINeovimMac.dSYM"
SHORT_VERSION="${SWUINVIM_SHORT_VERSION:-0.1.0}"

if [[ -n "${SWUINVIM_BUILD_VERSION:-}" ]]; then
  BUILD_VERSION="$SWUINVIM_BUILD_VERSION"
elif git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BUILD_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
else
  BUILD_VERSION="1"
fi

mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$BIN_PATH" "$APP_ROOT/Contents/MacOS/SWUINeovimMac"

if [[ "$CONFIGURATION" == "release" ]]; then
  rm -rf "$DSYM_PATH"
  dsymutil "$BIN_PATH" -o "$DSYM_PATH"
  strip -S -x "$APP_ROOT/Contents/MacOS/SWUINeovimMac"
fi

if [[ -d "$ICONSET_SOURCE" ]]; then
  TMP_ICONSET_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_ICONSET_DIR"' EXIT
  cp "$ICONSET_SOURCE"/*.png "$TMP_ICONSET_DIR/"
  mv "$TMP_ICONSET_DIR" "$TMP_ICONSET_DIR.iconset"
  iconutil -c icns "$TMP_ICONSET_DIR.iconset" -o "$ICON_FILE"
  rm -rf "$TMP_ICONSET_DIR.iconset"
  trap - EXIT
fi

cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SWUINeovimMac</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.aquaherd.swuinvim.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SWUINeovimMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Staged $CONFIGURATION app bundle: $APP_ROOT"
echo "Bundle version: $SHORT_VERSION ($BUILD_VERSION)"

if [[ "$CONFIGURATION" == "release" ]]; then
  echo "Generated release dSYM: $DSYM_PATH"
fi

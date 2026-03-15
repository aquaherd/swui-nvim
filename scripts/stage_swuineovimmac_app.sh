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

rm -f "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add : dict" "$INFO_PLIST"

plist_set() {
  local key="$1"
  local type="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$INFO_PLIST"
}

plist_set "CFBundleDevelopmentRegion" "string" "en"
plist_set "CFBundleExecutable" "string" "SWUINeovimMac"
plist_set "CFBundleIdentifier" "string" "com.aquaherd.swuinvim.mac"
plist_set "CFBundleInfoDictionaryVersion" "string" "6.0"
plist_set "CFBundleIconFile" "string" "$ICON_NAME"
plist_set "CFBundleName" "string" "SWUINeovimMac"
plist_set "CFBundlePackageType" "string" "APPL"
plist_set "CFBundleShortVersionString" "string" "0.1.0"
plist_set "CFBundleVersion" "string" "1"
plist_set "LSMinimumSystemVersion" "string" "14.0"
plist_set "NSHighResolutionCapable" "bool" "true"

echo "Staged $CONFIGURATION app bundle: $APP_ROOT"

if [[ "$CONFIGURATION" == "release" ]]; then
  echo "Generated release dSYM: $DSYM_PATH"
fi

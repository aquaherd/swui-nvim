#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build --product SWUINeovimMac

BIN_PATH="$ROOT_DIR/.build/arm64-apple-macosx/debug/SWUINeovimMac"
APP_ROOT="$ROOT_DIR/.build/arm64-apple-macosx/debug/SWUINeovimMac.app"
INFO_PLIST="$APP_ROOT/Contents/Info.plist"

mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$BIN_PATH" "$APP_ROOT/Contents/MacOS/SWUINeovimMac"

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
plist_set "CFBundleName" "string" "SWUINeovimMac"
plist_set "CFBundlePackageType" "string" "APPL"
plist_set "CFBundleShortVersionString" "string" "0.1.0"
plist_set "CFBundleVersion" "string" "1"
plist_set "LSMinimumSystemVersion" "string" "14.0"
plist_set "NSHighResolutionCapable" "bool" "true"

echo "Staged app bundle: $APP_ROOT"

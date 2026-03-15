#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-signed}"

case "$MODE" in
  signed)
    bash "$ROOT_DIR/scripts/sign_swuineovimmac_app.sh" release
    ;;
  notarized)
    bash "$ROOT_DIR/scripts/notarize_swuineovimmac_app.sh" release
    ;;
  *)
    echo "Usage: $0 [signed|notarized]" >&2
    exit 1
    ;;
esac

BUILD_DIR="$(swift build -c release --product SWUINeovimMac --show-bin-path)"
APP_ROOT="$BUILD_DIR/SWUINeovimMac.app"
DSYM_PATH="$BUILD_DIR/SWUINeovimMac.dSYM"
DIST_DIR="$ROOT_DIR/dist/release/$MODE"
APP_DIST="$DIST_DIR/SWUINeovimMac.app"
DSYM_DIST="$DIST_DIR/SWUINeovimMac.dSYM"
ZIP_DIST="$DIST_DIR/SWUINeovimMac-$MODE.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto "$APP_ROOT" "$APP_DIST"
if [[ -d "$DSYM_PATH" ]]; then
  ditto "$DSYM_PATH" "$DSYM_DIST"
fi
ditto -c -k --keepParent "$APP_DIST" "$ZIP_DIST"

echo "Packaged $MODE release app: $APP_DIST"
if [[ -d "$DSYM_DIST" ]]; then
  echo "Packaged dSYM: $DSYM_DIST"
fi
echo "Packaged zip: $ZIP_DIST"
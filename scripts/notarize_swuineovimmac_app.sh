#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${1:-release}"
KEYCHAIN_PROFILE="${SWUINVIM_NOTARY_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
APPLE_ID="${SWUINVIM_NOTARY_APPLE_ID:-}"
TEAM_ID="${SWUINVIM_NOTARY_TEAM_ID:-${SWUINVIM_DEVELOPMENT_TEAM:-}}"
APP_PASSWORD="${SWUINVIM_NOTARY_PASSWORD:-}"

case "$CONFIGURATION" in
  release)
    ;;
  *)
    echo "Usage: $0 [release]" >&2
    exit 1
    ;;
esac

bash "$ROOT_DIR/scripts/sign_swuineovimmac_app.sh" "$CONFIGURATION"

BUILD_DIR="$(swift build -c "$CONFIGURATION" --product SWUINeovimMac --show-bin-path)"
APP_ROOT="$BUILD_DIR/SWUINeovimMac.app"
ZIP_PATH="$BUILD_DIR/SWUINeovimMac-notarization.zip"
FINAL_ZIP_PATH="$BUILD_DIR/SWUINeovimMac-release.zip"

if ! codesign -dvv "$APP_ROOT" 2>&1 | rg -q '^Authority=Developer ID Application:'; then
  echo "Notarization requires a Developer ID Application signature." >&2
  echo "The current app bundle is not signed with Developer ID Application." >&2
  exit 1
fi

rm -f "$ZIP_PATH" "$FINAL_ZIP_PATH"
ditto -c -k --keepParent "$APP_ROOT" "$ZIP_PATH"

submit_args=(submit "$ZIP_PATH" --wait)
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  submit_args+=(--keychain-profile "$KEYCHAIN_PROFILE")
elif [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$APP_PASSWORD" ]]; then
  submit_args+=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "Configure notarization credentials with SWUINVIM_NOTARY_PROFILE or SWUINVIM_NOTARY_APPLE_ID, SWUINVIM_NOTARY_TEAM_ID, and SWUINVIM_NOTARY_PASSWORD." >&2
  exit 1
fi

xcrun notarytool "${submit_args[@]}"
xcrun stapler staple "$APP_ROOT"
xcrun stapler validate "$APP_ROOT"

ditto -c -k --keepParent "$APP_ROOT" "$FINAL_ZIP_PATH"

echo "Notarized app bundle: $APP_ROOT"
echo "Distributable zip: $FINAL_ZIP_PATH"
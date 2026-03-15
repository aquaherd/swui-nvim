#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${1:-release}"
DEVELOPMENT_TEAM="${SWUINVIM_DEVELOPMENT_TEAM:-}"
IDENTITY="${SWUINVIM_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
DEFAULT_ENTITLEMENTS="$ROOT_DIR/scripts/SWUINeovimMac.entitlements"
ENTITLEMENTS="${SWUINVIM_CODESIGN_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}"

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

select_identity() {
  local pattern="$1"

  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    security find-identity -v -p codesigning | awk -F '"' -v team="$DEVELOPMENT_TEAM" -v pattern="$pattern" '$2 ~ pattern && $2 ~ "\\(" team "\\)$" { print $2; exit }'
  else
    security find-identity -v -p codesigning | awk -F '"' -v pattern="$pattern" '$2 ~ pattern { print $2; exit }'
  fi
}

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(select_identity '^Developer ID Application: ')"
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(select_identity '^Apple Development: ')"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "No usable signing identity found in the keychain." >&2
  echo "Install a Developer ID Application certificate for distribution, or an Apple Development certificate for local signing." >&2
  echo "Set SWUINVIM_CODESIGN_IDENTITY or CODESIGN_IDENTITY explicitly if needed." >&2
  exit 1
fi

if [[ -z "$DEVELOPMENT_TEAM" && "$IDENTITY" =~ \(([A-Z0-9]+)\)$ ]]; then
  DEVELOPMENT_TEAM="${BASH_REMATCH[1]}"
fi

bash "$ROOT_DIR/scripts/stage_swuineovimmac_app.sh" "$CONFIGURATION"

BUILD_DIR="$(swift build -c "$CONFIGURATION" --product SWUINeovimMac --show-bin-path)"
APP_ROOT="$BUILD_DIR/SWUINeovimMac.app"

codesign_args=(
  --force
  --sign "$IDENTITY"
)

if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
  codesign_args+=(--timestamp --options runtime)
fi

if [[ -n "$ENTITLEMENTS" ]]; then
  codesign_args+=(--entitlements "$ENTITLEMENTS")
fi

codesign "${codesign_args[@]}" "$APP_ROOT"
codesign --verify --deep --strict --verbose=2 "$APP_ROOT"

echo "Using signing identity: $IDENTITY"
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  echo "Using team: $DEVELOPMENT_TEAM"
fi
if [[ "$IDENTITY" == Apple\ Development:* ]]; then
  echo "Note: Apple Development signing is suitable for local testing, not notarized external distribution." 
fi
echo "Signed app bundle: $APP_ROOT"
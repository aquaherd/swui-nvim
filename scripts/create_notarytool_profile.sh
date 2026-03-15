#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE_NAME="${1:-${SWUINVIM_NOTARY_PROFILE:-}}"
APPLE_ID="${SWUINVIM_NOTARY_APPLE_ID:-}"
TEAM_ID="${SWUINVIM_NOTARY_TEAM_ID:-${SWUINVIM_DEVELOPMENT_TEAM:-}}"
APP_PASSWORD="${SWUINVIM_NOTARY_PASSWORD:-}"

if [[ -z "$PROFILE_NAME" ]]; then
  echo "Usage: $0 <profile-name>" >&2
  echo "Or set SWUINVIM_NOTARY_PROFILE in the environment." >&2
  exit 1
fi

if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$APP_PASSWORD" ]]; then
  echo "Set SWUINVIM_NOTARY_APPLE_ID, SWUINVIM_NOTARY_TEAM_ID, and SWUINVIM_NOTARY_PASSWORD first." >&2
  exit 1
fi

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD"

echo "Stored notarytool profile: $PROFILE_NAME"
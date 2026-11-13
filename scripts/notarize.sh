#!/usr/bin/env bash
# Explicit release action; requires a Developer ID signed app and a stored notary profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Jamun.app"
: "${JAMUN_NOTARY_PROFILE:?Set JAMUN_NOTARY_PROFILE to your notarytool keychain profile}"
[[ -d "$APP" ]] || { echo "Build the release app first." >&2; exit 1; }
ARCHIVE="$ROOT/build/Jamun-notarization.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$JAMUN_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
echo "Notarized and stapled $APP"

#!/usr/bin/env bash
# Build, verify and zip a shareable app. Signing uses the local development
# identity (or ad-hoc), so recipients must approve the first launch themselves.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(node -p "require('./package.json').version")"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Warning: uncommitted changes; this build will be marked -dirty." >&2
fi
npm run check
npm run build
APP="$ROOT/build/Jamun.app"
./scripts/test-package.sh "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/JamunHost" | tr ' ' '-')"
OUT_DIR="$ROOT/build/release"
ARCHIVE="$OUT_DIR/Jamun-$VERSION-$ARCH.zip"
mkdir -p "$OUT_DIR"
rm -f "$ARCHIVE"
# ditto keeps the signature and extended attributes intact; plain zip does not.
ditto -c -k --keepParent "$APP" "$ARCHIVE"
echo
echo "Release: $ARCHIVE"
echo "Version: $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") (build $(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"), $(plutil -extract JamunCommit raw "$APP/Contents/Info.plist"))"
echo "SHA-256: $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"

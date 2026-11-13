#!/usr/bin/env bash
# Build a self-contained app. Does not modify ~/.jamun or shell configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${JAMUN_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/Jamun.app"
SPECS="$ROOT/node_modules/@withfig/autocomplete"
for required in "$ROOT/packages/web/dist/index.html" "$SPECS/build/index.json" "$ROOT/shell/jamun.zsh"; do
  [[ -f "$required" ]] || { echo "Missing required resource: $required. Run npm ci and npm run build:web first." >&2; exit 1; }
done
[[ -d "$SPECS/icons" ]] || { echo "Missing bundled spec icons" >&2; exit 1; }
swift build -c release --package-path "$ROOT/host"
BIN_DIR="$(swift build -c release --package-path "$ROOT/host" --show-bin-path)"
mkdir -p "$BUILD_DIR"
STAGING="$(mktemp -d "$BUILD_DIR/.jamun-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/Jamun.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/shell" "$BUNDLE/Contents/Resources/licenses"
cp "$BIN_DIR/JamunHost" "$BUNDLE/Contents/MacOS/JamunHost"
cp "$ROOT/host/Info.plist" "$BUNDLE/Contents/Info.plist"
cp -R "$ROOT/packages/web/dist" "$BUNDLE/Contents/Resources/web"
cp -R "$SPECS/build" "$BUNDLE/Contents/Resources/specs"
cp -R "$SPECS/icons" "$BUNDLE/Contents/Resources/icons"
cp "$ROOT/shell/jamun.zsh" "$BUNDLE/Contents/Resources/shell/jamun.zsh"
cp "$ROOT/packages/LICENSE.fig.APACHE" "$ROOT/packages/LICENSE.fig.MIT" "$BUNDLE/Contents/Resources/licenses/"
cp "$ROOT/packages/fuzzysort/LICENSE" "$BUNDLE/Contents/Resources/licenses/fuzzysort.LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/Contents/Resources/licenses/"
# Include the actual license distributed with the locked spec package.
for license in "$SPECS"/LICENSE*; do
  if [[ -f "$license" ]]; then cp "$license" "$BUNDLE/Contents/Resources/licenses/specs-$(basename "$license")"; fi
done
IDENTITY="${JAMUN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && ${JAMUN_RELEASE:-0} != 1 ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
fi
if [[ ${JAMUN_RELEASE:-0} == 1 ]]; then
  [[ -n "$IDENTITY" ]] || { echo "Release builds require JAMUN_SIGN_IDENTITY (Developer ID Application)." >&2; exit 1; }
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
else
  codesign --force --sign "${IDENTITY:--}" "$BUNDLE"
fi
# Keep the previous working app until the replacement is fully assembled and signed.
rm -rf "$APP.previous"
[[ ! -d "$APP" ]] || mv "$APP" "$APP.previous"
if ! mv "$BUNDLE" "$APP"; then
  [[ ! -d "$APP.previous" ]] || mv "$APP.previous" "$APP"
  exit 1
fi
echo "Built $APP (previous build retained as Jamun.app.previous)."

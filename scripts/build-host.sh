#!/usr/bin/env bash
# Builds the Swift host and assembles a signed build/Jamun.app.
# Signing with a stable identity keeps the Accessibility grant across rebuilds.
# Override the identity with JAMUN_SIGN_IDENTITY, otherwise the first
# "Apple Development" identity in the keychain is used (ad-hoc if none).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Jamun.app"

swift build -c release --package-path "$ROOT/host"
BIN_DIR="$(swift build -c release --package-path "$ROOT/host" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/JamunHost" "$APP/Contents/MacOS/JamunHost"
cp "$ROOT/host/Info.plist" "$APP/Contents/Info.plist"

# Web app (run `npm run build:web` first).
if [[ -d "$ROOT/packages/web/dist" ]]; then
  mkdir -p "$APP/Contents/Resources"
  cp -R "$ROOT/packages/web/dist" "$APP/Contents/Resources/web"
else
  echo "warning: packages/web/dist is missing, the popup will be empty"
fi

# Specs, icons, and the shell integration are linked into ~/.jamun so they can
# change without re-signing the app.
mkdir -p "$HOME/.jamun"
ln -sfn "$ROOT/node_modules/@withfig/autocomplete/build" "$HOME/.jamun/specs"
ln -sfn "$ROOT/node_modules/@withfig/autocomplete/icons" "$HOME/.jamun/icons"
ln -sfn "$ROOT/shell/jamun.zsh" "$HOME/.jamun/jamun.zsh"

IDENTITY="${JAMUN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
fi

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with identity $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "warning: ad-hoc signed, Accessibility permission will reset on every rebuild"
fi

echo "built $APP"

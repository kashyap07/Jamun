#!/usr/bin/env bash
# Regenerate the committed icon artefacts from assets/icon/Jamun.icon.
# Needs Icon Composer (for ictool) and ImageMagick. Only run after editing the icon;
# the app build just copies the committed Jamun.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$ROOT/assets/icon"
ICTOOL="${ICTOOL:-/Applications/Icon Composer.app/Contents/Executables/ictool}"
[[ -x "$ICTOOL" ]] || { echo "Missing ictool. Install Icon Composer or set ICTOOL." >&2; exit 1; }
command -v magick >/dev/null || { echo "Missing ImageMagick (magick)." >&2; exit 1; }
WORK="$(mktemp -d /tmp/jamun-icon-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

"$ICTOOL" "$ICON_DIR/Jamun.icon" --export-image --output-file "$WORK/full.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
[[ -s "$WORK/full.png" ]] || { echo "ictool did not render the icon." >&2; exit 1; }

# ictool renders full bleed. macOS icons sit on an 824 point shape inside a 1024 canvas.
magick "$WORK/full.png" -resize 824x824 -background none -gravity center -extent 1024x1024 "$WORK/master.png"

SET="$WORK/Jamun.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  magick "$WORK/master.png" -resize "${size}x${size}" "$SET/icon_${size}x${size}.png"
  double=$((size * 2))
  magick "$WORK/master.png" -resize "${double}x${double}" "$SET/icon_${size}x${size}@2x.png"
done
iconutil --convert icns --output "$ICON_DIR/Jamun.icns" "$SET"
magick "$WORK/master.png" -resize 512x512 "$ICON_DIR/jamun.png"
echo "Wrote $ICON_DIR/Jamun.icns and $ICON_DIR/jamun.png"

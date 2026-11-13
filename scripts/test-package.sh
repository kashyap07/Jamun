#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$ROOT/build/validation/Jamun.app}"
TEMP_DIR="$(mktemp -d /tmp/jamun-package-XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ditto "$SOURCE_APP" "$TEMP_DIR/Jamun.app"
codesign --verify --deep --strict "$TEMP_DIR/Jamun.app"
plutil -lint "$TEMP_DIR/Jamun.app/Contents/Info.plist"
python3 - "$TEMP_DIR/Jamun.app" <<'PY'
from pathlib import Path
import sys
app = Path(sys.argv[1])
required = ["Contents/MacOS/JamunHost", "Contents/Resources/web/index.html", "Contents/Resources/specs/index.json", "Contents/Resources/shell/jamun.zsh", "Contents/Resources/Jamun.icns", "Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"]
for name in required:
    assert (app / name).is_file() and (app / name).stat().st_size > 0, name
assert any((app / "Contents/Resources/icons").iterdir())
assert not [path for path in app.rglob("*") if path.is_symlink()], "Bundle contains symlinks"
print("Package: required resources present; no checkout symlinks")
PY
"$ROOT/scripts/test-webkit.sh" "$TEMP_DIR/Jamun.app"

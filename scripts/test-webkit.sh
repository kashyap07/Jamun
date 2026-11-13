#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d /tmp/jamun-webkit-XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -o "$TEMP_DIR/tests" "$ROOT/scripts/tests/webkit/main.swift" "$ROOT/host/Sources/JamunHost/SchemeHandler.swift" -framework AppKit -framework WebKit
"$TEMP_DIR/tests" "${1:-$ROOT}"

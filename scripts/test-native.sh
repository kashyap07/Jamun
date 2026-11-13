#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d /tmp/jamun-native-XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -o "$TEMP_DIR/tests" "$ROOT/scripts/tests/native/main.swift" \
  "$ROOT/host/Sources/JamunHost/ProcessRunner.swift" \
  "$ROOT/host/Sources/JamunHost/SocketServer.swift" \
  "$ROOT/host/Sources/JamunHost/ShellIntegration.swift" \
  "$ROOT/host/Sources/JamunHost/SpecPolicy.swift" \
  "$ROOT/host/Sources/JamunHost/Settings.swift" \
  "$ROOT/host/Sources/JamunHost/Paths.swift" \
  "$ROOT/host/Sources/JamunHost/Log.swift"
"$TEMP_DIR/tests"

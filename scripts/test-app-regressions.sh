#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stillepost-paste.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
if [ -d "$BIN_DIR/Modules" ]; then
    MODULE_DIR="$BIN_DIR/Modules"
    OBJECTS=("$BIN_DIR"/StillePostCore.build/*.o)
else
    MODULE_DIR="$BIN_DIR"
    OBJECTS=("$BIN_DIR/StillePostCore.o")
fi
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/PasteService.swift scripts/fixtures/paste-regression.swift \
    "${OBJECTS[@]}" -o "$TEST_DIR/paste-regression"
"$TEST_DIR/paste-regression"
ditto "$BIN_DIR/StillePost_StillePostCore.bundle" "$TEST_DIR/StillePost_StillePostCore.bundle"
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/HistoryEditor.swift Sources/StillePost/HistoryWindow.swift \
    scripts/fixtures/editor-regression.swift "${OBJECTS[@]}" -o "$TEST_DIR/editor-regression"
"$TEST_DIR/editor-regression"

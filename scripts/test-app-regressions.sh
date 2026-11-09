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
swiftc -parse-as-library Sources/StillePost/StatusItemController.swift \
    scripts/fixtures/status-item-regression.swift -o "$TEST_DIR/status-item-regression"
"$TEST_DIR/status-item-regression"
ditto "$BIN_DIR/StillePost_StillePostCore.bundle" "$TEST_DIR/StillePost_StillePostCore.bundle"
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/HistoryEditor.swift Sources/StillePost/HistoryWindow.swift \
    scripts/fixtures/editor-regression.swift "${OBJECTS[@]}" -o "$TEST_DIR/editor-regression"
"$TEST_DIR/editor-regression"
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/HotkeyManager.swift Sources/StillePost/DiagnosticsWindow.swift \
    scripts/fixtures/diagnostics-regression.swift "${OBJECTS[@]}" -o "$TEST_DIR/diagnostics-regression"
"$TEST_DIR/diagnostics-regression"
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/AudioImportWindow.swift scripts/fixtures/audio-import-selection-regression.swift \
    Sources/StillePost/TranscriptOriginLabel.swift \
    "${OBJECTS[@]}" -o "$TEST_DIR/audio-import-selection-regression"
"$TEST_DIR/audio-import-selection-regression"
mkdir -p "$TEST_DIR/OverlayProbe.app/Contents/MacOS" "$TEST_DIR/OverlayProbe.app/Contents/Resources"
cat > "$TEST_DIR/OverlayProbe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.stillepost.overlayprobe</string>
<key>CFBundleExecutable</key><string>OverlayProbe</string><key>LSUIElement</key><true/>
</dict></plist>
PLIST
ditto "$BIN_DIR/StillePost_StillePostCore.bundle" "$TEST_DIR/OverlayProbe.app/Contents/Resources/StillePost_StillePostCore.bundle"
swiftc -parse-as-library -I "$MODULE_DIR" \
    Sources/StillePost/OverlayController.swift scripts/fixtures/overlay-regression.swift \
    "${OBJECTS[@]}" -o "$TEST_DIR/OverlayProbe.app/Contents/MacOS/OverlayProbe"
"$TEST_DIR/OverlayProbe.app/Contents/MacOS/OverlayProbe"

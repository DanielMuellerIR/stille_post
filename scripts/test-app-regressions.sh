#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --filter StillePostAppTests
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

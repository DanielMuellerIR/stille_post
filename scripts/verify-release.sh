#!/bin/bash
# Prüft ein veröffentlichtes DMG vollständig, bevor Sparkle ihm mit dem
# Update-Schlüssel vertraut. Das Skript mountet nur read-only und installiert nichts.
set -euo pipefail

if (( $# != 3 )); then
    echo "Verwendung: $0 <StillePost.dmg> <vX.Y.Z> <Developer-Team-ID>" >&2
    exit 2
fi

DMG=$1
RELEASE_TAG=$2
EXPECTED_TEAM_ID=$3
EXPECTED_BUNDLE_ID="io.github.danielmuellerir.stillepost"

if [[ ! -f "$DMG" ]]; then
    echo "FEHLER: DMG fehlt: $DMG" >&2
    exit 1
fi
if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "FEHLER: Release-Tag muss vX.Y.Z entsprechen: $RELEASE_TAG" >&2
    exit 1
fi
if [[ -z "$EXPECTED_TEAM_ID" ]]; then
    echo "FEHLER: erwartete Developer-Team-ID fehlt." >&2
    exit 1
fi
EXPECTED_VERSION=${RELEASE_TAG#v}

team_id() {
    local target=$1
    local metadata
    metadata=$(codesign -dv --verbose=4 "$target" 2>&1)
    sed -n 's/^TeamIdentifier=//p' <<<"$metadata" | head -1
}

assert_team() {
    local target=$1
    local actual
    actual=$(team_id "$target")
    if [[ "$actual" != "$EXPECTED_TEAM_ID" ]]; then
        echo "FEHLER: falsche Team-ID für $target: ${actual:-<leer>}" >&2
        exit 1
    fi
}

echo "Prüfe DMG-Signatur, Notary-Ticket und Gatekeeper …"
codesign --verify --strict --verbose=2 "$DMG"
assert_team "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/stillepost-release.XXXXXX")
mounted=0
cleanup() {
    if (( mounted )); then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG" >/dev/null
mounted=1

apps=()
while IFS= read -r -d '' app; do
    apps+=("$app")
done < <(find "$MOUNT_DIR" -maxdepth 2 -type d -name 'StillePost.app' -print0)
if (( ${#apps[@]} != 1 )); then
    echo "FEHLER: DMG muss genau eine StillePost.app enthalten." >&2
    exit 1
fi
APP=${apps[0]}
PLIST="$APP/Contents/Info.plist"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "FEHLER: falsche Bundle-ID: $bundle_id" >&2
    exit 1
fi
if [[ "$short_version" != "$EXPECTED_VERSION" || "$bundle_version" != "$EXPECTED_VERSION" ]]; then
    echo "FEHLER: Tag $RELEASE_TAG passt nicht zu Bundle-Versionen $short_version/$bundle_version." >&2
    exit 1
fi

echo "Prüfe App-Signatur, Team-ID, Notary-Ticket und Gatekeeper …"
codesign --verify --deep --strict --verbose=2 "$APP"
assert_team "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "Prüfe eingebettete Binaries und Frameworks einzeln …"
# build-app.sh signiert diese Ziele einzeln — hier werden sie auch einzeln
# geprüft: `--deep` oben validiert zwar die SignaturKETTE, vergleicht aber
# KEINE Team-IDs der verschachtelten Ziele. Ein äußerlich korrekt signiertes
# Bundle mit fremd signiertem eingebettetem Code darf nicht als Release
# durchgehen. Fehlt eines der erwarteten Ziele, ist das ebenfalls ein Fehler
# (fail closed).
NESTED_TARGETS=(
    "$APP/Contents/MacOS/stillepost-cli"
    "$APP/Contents/Frameworks/Sparkle.framework"
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
)
for target in "${NESTED_TARGETS[@]}"; do
    if [[ ! -e "$target" ]]; then
        echo "FEHLER: erwartetes eingebettetes Ziel fehlt: $target" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$target"
    assert_team "$target"
done

echo "Release verifiziert: $RELEASE_TAG, $bundle_id, Team $EXPECTED_TEAM_ID"

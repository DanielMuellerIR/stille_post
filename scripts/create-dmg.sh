#!/bin/bash
# Erzeugt ein DMG aus einem bereits signierten (und idealerweise gestapelten)
# App-Bundle. Das Image enthält die App und einen Alias auf /Applications, damit
# der Nutzer sie im Finder einfach hinüberziehen kann.
#
# Das DMG entsteht vollständig in einem temporären Ordner und wird erst am Ende
# an sein Ziel verschoben. Ein bereits vorhandenes Ziel wird NIE überschrieben —
# sonst stünde unter dem finalen Namen zwischenzeitlich ein halbfertiges Image.
#
# Verwendung: scripts/create-dmg.sh <StillePost.app> <Ausgabe.dmg>
set -euo pipefail

if (( $# != 2 )); then
    echo "Verwendung: $0 <StillePost.app> <Ausgabe.dmg>" >&2
    exit 2
fi

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_DIRECTORY="$(cd "$(dirname "$2")" && pwd)"
OUTPUT="$OUTPUT_DIRECTORY/$(basename "$2")"

if [[ ! -d "$APP" ]]; then
    echo "FEHLER: App-Bundle fehlt: $APP" >&2
    exit 1
fi
if [[ "$OUTPUT" != *.dmg ]]; then
    echo "FEHLER: Das Ausgabeziel muss auf .dmg enden: $OUTPUT" >&2
    exit 2
fi
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo "FEHLER: Das DMG-Ziel existiert bereits: $OUTPUT" >&2
    exit 3
fi

TEMPORARY_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.stillepost-dmg.XXXXXX")"
cleanup() {
    [[ -d "$TEMPORARY_DIRECTORY" ]] && rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

STAGING="$TEMPORARY_DIRECTORY/staging"
STAGED_DMG="$TEMPORARY_DIRECTORY/StillePost.dmg"
mkdir -p "$STAGING"
# ditto statt cp: erhält Signatur, Rechte und erweiterte Attribute des Bundles.
ditto "$APP" "$STAGING/StillePost.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Stille Post" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$STAGED_DMG" >/dev/null
hdiutil verify "$STAGED_DMG" >/dev/null

# Atomar und ohne Überschreiben ans Ziel: link(2) scheitert, wenn das Ziel
# seit der Vorabprüfung oben entstanden ist — ein bloßes mv hätte dieses
# Zeitfenster offen gelassen. Quelle und Ziel liegen im selben Dateisystem
# (Temp-Ordner neben dem Ziel), ein Hardlink ist daher immer möglich; der
# Temp-Ordner samt Staging-Hardlink verschwindet über den EXIT-Trap.
# `link` statt `ln`: Steht am Zielpfad inzwischen ein Verzeichnis (oder ein
# Symlink darauf), legt `ln` das DMG kommentarlos DARIN ab und meldet Erfolg.
# `link` ruft link(2) direkt auf und scheitert auch in diesem Fall.
if ! link "$STAGED_DMG" "$OUTPUT"; then
    echo "FEHLER: Das DMG-Ziel konnte nicht atomar angelegt werden (existiert es inzwischen?): $OUTPUT" >&2
    exit 3
fi
echo "DMG OK: $OUTPUT"

#!/bin/bash
# Erzeugt aus den SVG-Quellen in Resources/icon/ das fertige App-Icon
# Resources/AppIcon.icns.
#
# Das Ergebnis liegt im Repo, damit scripts/build-app.sh das Icon nur noch kopieren
# muss und ohne Zusatzwerkzeug auskommt. Dieses Skript ist deshalb NUR nötig, wenn
# jemand die Zeichnung ändert — dann laufen lassen und das neue .icns mitcommitten.
#
#   scripts/build-icon.sh
#
# Voraussetzung: rsvg-convert (brew install librsvg). iconutil bringt macOS mit.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "FEHLER: rsvg-convert fehlt — 'brew install librsvg'." >&2
    echo "(Nur zum Neuzeichnen des Icons nötig; der App-Build braucht es nicht.)" >&2
    exit 1
fi

FULL="Resources/icon/AppIcon.svg"
SMALL="Resources/icon/AppIcon-small.svg"
ICONSET="build/AppIcon.iconset"
OUT="Resources/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET" build

# render <quell-svg> <kantenlänge-px> <zieldateiname>
render() {
    rsvg-convert --width="$2" --height="$3" --output="$ICONSET/$4" "$1"
}

# Kleine Größen aus der reduzierten Zeichnung, große aus der vollen. Die Grenze
# liegt zwischen 32 und 64 px und ist ausgemessen, nicht geraten: bei 32 px
# verschmieren die fünf feinen Balken der Vollversion zu einem Fleck, bei 64 px
# stehen sie sauber — und sind dort der reduzierten Zeichnung sichtbar überlegen.
echo "Rendere kleine Größen (16, 32) aus $SMALL …"
render "$SMALL" 16   16   icon_16x16.png
render "$SMALL" 32   32   icon_16x16@2x.png
render "$SMALL" 32   32   icon_32x32.png

echo "Rendere große Größen (64 und aufwärts) aus $FULL …"
render "$FULL"  64   64   icon_32x32@2x.png
render "$FULL"  128  128  icon_128x128.png
render "$FULL"  256  256  icon_128x128@2x.png
render "$FULL"  256  256  icon_256x256.png
render "$FULL"  512  512  icon_256x256@2x.png
render "$FULL"  512  512  icon_512x512.png
render "$FULL"  1024 1024 icon_512x512@2x.png

echo "Baue $OUT …"
iconutil --convert icns --output "$OUT" "$ICONSET"
rm -rf "$ICONSET"

echo "Fertig: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Nicht vergessen: $OUT mitcommitten, danach scripts/build-app.sh."

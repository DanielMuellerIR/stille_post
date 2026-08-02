#!/bin/bash
# build.sh — Root-Einstiegspunkt: App bauen, mehr nicht.
#
# Ruft scripts/build-app.sh bewusst OHNE Argumente auf. Das Ergebnis bleibt in
# build/StillePost.app; weder notarisiert noch installiert. Argumente werden
# abgelehnt, sonst wäre die Trennung wirkungslos: `./build.sh --notarize
# --install` würde sonst über den harmlos benannten Einstieg notarisieren und
# nach /Applications installieren.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     baut die App nach build/, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG — installiert nie
set -euo pipefail
cd "$(dirname "$0")"

if (( $# > 0 )); then
    echo "FEHLER: build.sh nimmt keine Argumente — es baut nur nach build/." >&2
    echo "Notarisieren/Installieren: ./install.sh, Release-DMG: ./release.sh" >&2
    exit 2
fi

exec scripts/build-app.sh

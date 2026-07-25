#!/bin/bash
# build.sh — Root-Einstiegspunkt: App bauen, mehr nicht.
#
# Reicht unverändert an scripts/build-app.sh durch. Das Ergebnis bleibt in
# build/StillePost.app; weder notarisiert noch installiert.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     baut die App nach build/, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG — installiert nie
set -euo pipefail
cd "$(dirname "$0")"

exec scripts/build-app.sh "$@"

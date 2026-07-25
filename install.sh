#!/bin/bash
# install.sh — Root-Einstiegspunkt: bauen, notarisieren, nach /Applications.
#
# Kein DMG — das baut ./release.sh. In /Applications gehören nur Bundles mit
# angeheftetem Notary-Ticket, deshalb läuft dieser Weg immer notarisiert.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     baut die App nach build/, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG — installiert nie
#
# Voraussetzung: NOTARY_PROFILE, ersatzweise der clone-lokale Wert aus
# `git config stillePost.notaryProfile`.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_PROFILE="$(git config --local --get stillePost.notaryProfile 2>/dev/null || true)"
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "FEHLER: Kein Notary-Profil bekannt." >&2
    echo "Entweder NOTARY_PROFILE setzen oder einmalig für diesen Clone:" >&2
    echo "  git config --local stillePost.notaryProfile <profil>" >&2
    exit 2
fi
export NOTARY_PROFILE

exec scripts/build-app.sh --notarize --install "$@"

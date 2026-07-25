#!/bin/bash
# release.sh — Release-DMG bauen: bauen, notarisieren, DMG packen, DMG notarisieren.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     baut die App nach build/, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG — installiert NIE
#
# Warum das wichtig ist: Sparkle bietet jedem Nutzer genau das DMG an, das im
# signierten Appcast steht. Ein von Hand zusammengeklicktes Image ist deshalb die
# riskanteste Stelle im ganzen Projekt. Dieses Skript macht den Weg reproduzierbar
# und prüft das Ergebnis mit demselben `verify-release.sh`, das auch die CI fährt.
#
# Ablauf:
#   1. scripts/build-app.sh --notarize  (Release-Build, Developer-ID-Signatur,
#      Hardened Runtime, Apple-Notarisierung, Ticket angeheftet)
#   2. DMG in build/ erzeugen (App + /Applications-Alias)
#   3. DMG signieren, bei Apple notarisieren, Ticket anheften
#   4. Vollständige Prüfung des DMG über scripts/verify-release.sh
#   5. Erst dann DMG + SHA-256 ins Repo-Root veröffentlichen — ohne Überschreiben
#
# Voraussetzungen:
#   NOTARY_PROFILE   notarytool-Keychain-Profil. Fehlt die Variable, greift der
#                    clone-lokale Wert aus `git config stillePost.notaryProfile`.
#                    Einmalig pro Mac anlegen:
#                      xcrun notarytool store-credentials <name> \
#                        --apple-id <apple-id> --team-id <team-id>
#                    (Das App-Passwort wird verdeckt abgefragt — nie als Argument.)
#
# Aufruf:  ./release.sh
# Letzte Zeile bei Erfolg (maschinenlesbar): RELEASE OK: <pfad-zum-dmg> (<version>)
set -euo pipefail
cd "$(dirname "$0")"

# Profilname: Umgebung schlägt clone-lokale Git-Konfiguration. Der echte Name
# bleibt damit außerhalb des öffentlichen Repos.
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

VERSION="$(cat VERSION)"
APP="build/StillePost.app"
STAGED_DMG="build/StillePost-$VERSION.dmg"
FINAL_DMG="StillePost-$VERSION.dmg"
FINAL_CHECKSUM="$FINAL_DMG.sha256"

# Vor dem ersten teuren Schritt prüfen: ein fertiges Release dieser Version darf
# nicht überschrieben werden. Sonst merkt man es erst nach zwei Apple-Roundtrips.
for artifact in "$FINAL_DMG" "$FINAL_CHECKSUM"; do
    if [[ -e "$artifact" || -L "$artifact" ]]; then
        echo "FEHLER: Release-Artefakt existiert bereits und wird nicht überschrieben: $artifact" >&2
        exit 3
    fi
done
rm -f "$STAGED_DMG"

echo "== 1/5 App bauen und notarisieren =="
scripts/build-app.sh --notarize

echo "== 2/5 DMG erzeugen =="
scripts/create-dmg.sh "$APP" "$STAGED_DMG"

echo "== 3/5 DMG signieren und notarisieren =="
# Signatur-Identität aus der bereits signierten App übernehmen: so kann das DMG
# gar nicht mit einem anderen Zertifikat signiert werden als die App darin.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "FEHLER: Die App trägt keine Developer-ID-Signatur — ein Release-DMG wäre wertlos." >&2
    exit 4
fi
codesign --force --sign "$IDENTITY" --timestamp "$STAGED_DMG"
xcrun notarytool submit "$STAGED_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$STAGED_DMG"

echo "== 4/5 DMG prüfen =="
TEAM_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -1)"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
    echo "FEHLER: Team-ID der App nicht lesbar." >&2
    exit 4
fi
scripts/verify-release.sh "$STAGED_DMG" "v$VERSION" "$TEAM_ID"

echo "== 5/5 veröffentlichen =="
# Die Prüfsumme zuerst, das DMG zuletzt: erst mit dem DMG ist das Paar vollständig.
# Im Ordner des DMG rechnen, damit nur der Dateiname in der Zeile steht — und das
# exakte Format von `shasum -c` erhalten bleibt (zwei Leerzeichen als Trenner).
# Der Staging-Name ist bereits der finale, ein Umschreiben der Zeile entfällt.
( cd "$(dirname "$STAGED_DMG")" && shasum -a 256 "$(basename "$STAGED_DMG")" ) > "$FINAL_CHECKSUM"
if ! mv "$STAGED_DMG" "$FINAL_DMG"; then
    rm -f "$FINAL_CHECKSUM"
    echo "FEHLER: Das fertige DMG konnte nicht veröffentlicht werden." >&2
    exit 5
fi

echo "RELEASE OK: $PWD/$FINAL_DMG ($VERSION)"

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
#   DEVELOPER_TEAM_ID  Erwartete Developer-Team-ID der Signatur. Fehlt die
#                    Variable, greift `git config stillePost.teamId`. Einmalig
#                    pro Clone: `git config --local stillePost.teamId <id>`.
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

# Erwartete Developer-Team-ID: Umgebung schlägt clone-lokale Git-Konfiguration.
# Bewusst NICHT aus der gerade gebauten App gelesen — dann prüfte das Release
# sich selbst gegen sich selbst, und eine vollständig mit der falschen
# Developer-ID signierte App samt DMG bestünde den Vergleich. Der
# GitHub-Workflow reicht dafür die Repo-Variable DEVELOPER_TEAM_ID durch.
# Hier oben und nicht erst in Schritt 4, damit ein fehlender Wert vor den
# teuren Build- und Notary-Schritten auffällt.
if [[ -z "${DEVELOPER_TEAM_ID:-}" ]]; then
    DEVELOPER_TEAM_ID="$(git config --local --get stillePost.teamId 2>/dev/null || true)"
fi
if [[ -z "$DEVELOPER_TEAM_ID" ]]; then
    echo "FEHLER: Keine erwartete Developer-Team-ID bekannt." >&2
    echo "Entweder DEVELOPER_TEAM_ID setzen oder einmalig für diesen Clone:" >&2
    echo "  git config --local stillePost.teamId <team-id>" >&2
    exit 2
fi

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
scripts/verify-release.sh "$STAGED_DMG" "v$VERSION" "$DEVELOPER_TEAM_ID"

echo "== 5/5 veröffentlichen =="
# Atomar und ohne Überschreiben: link(2) scheitert, wenn das Ziel INZWISCHEN
# existiert. Die Vorabprüfung am Skriptanfang lässt zwischen Prüfung und
# Veröffentlichung stundenlange Build-/Notary-Schritte zu — erst der Hardlink
# schließt dieses Zeitfenster (z. B. gegen einen parallel gestarteten Lauf).
#
# `link` statt `ln`: `ln quelle ziel` legt den Link IN das Ziel, wenn dort
# inzwischen ein Verzeichnis (oder ein Symlink auf eines) steht — das Skript
# meldete dann RELEASE OK, obwohl unter dem angekündigten Namen kein DMG liegt.
# `link` ruft link(2) direkt auf und scheitert in genau diesem Fall.
publish_no_clobber() {
    local source=$1 destination=$2
    if ! link "$source" "$destination"; then
        echo "FEHLER: Release-Artefakt konnte nicht atomar angelegt werden (existiert es inzwischen?): $destination" >&2
        return 1
    fi
    rm -f "$source"
}

# Die Prüfsumme vollständig im Staging erzeugen; im Ordner des DMG rechnen,
# damit nur der Dateiname in der Zeile steht — und das exakte Format von
# `shasum -c` erhalten bleibt (zwei Leerzeichen als Trenner). Der Staging-Name
# ist bereits der finale, ein Umschreiben der Zeile entfällt.
STAGED_CHECKSUM="$STAGED_DMG.sha256"
# Erst wegräumen, dann schreiben: `>` folgt einem vorhandenen Symlink und würde
# dessen Ziel kürzen — `build/` ist git-ignoriert, dort kann alles Mögliche
# liegen. `rm -f` entfernt den Symlink selbst, die Umleitung legt danach eine
# frische reguläre Datei an (genau wie oben beim Staging-DMG).
rm -f "$STAGED_CHECKSUM"
( cd "$(dirname "$STAGED_DMG")" && shasum -a 256 "$(basename "$STAGED_DMG")" ) > "$STAGED_CHECKSUM"

# Die Prüfsumme zuerst, das DMG zuletzt: erst mit dem DMG ist das Paar
# vollständig. Zwischen beiden Schritten hängt die veröffentlichte Prüfsumme an
# einem Trap: Bricht der Lauf hier ab (Ctrl-C, Abschuss, Fehler), bliebe sonst
# eine einzelne .sha256 im Repo-Root liegen — und die Vorabprüfung am
# Skriptanfang würde jeden Wiederholungsversuch blockieren, bis jemand von Hand
# aufräumt.
# BEGIN RELEASE_PUBLICATION_HELPERS
published_checksum=""
release_pair_complete=0
rollback_checksum() {
    if [[ -n "$published_checksum" ]]; then
        # Ein Signal kann genau nach dem erfolgreichen DMG-link(2), aber vor
        # der nächsten Shell-Zuweisung ankommen. Solange das Staging-DMG noch
        # existiert, beweist die gemeinsame Inode-Identität, dass das finale
        # DMG wirklich unser gerade veröffentlichtes Artefakt ist. Dann ist das
        # Paar vollständig und die Prüfsumme darf nicht einzeln verschwinden.
        if [[ "$release_pair_complete" -eq 1 ]] \
           || [[ -f "$STAGED_DMG" && -f "$FINAL_DMG" && ! -L "$FINAL_DMG" \
                 && "$STAGED_DMG" -ef "$FINAL_DMG" ]]; then
            return
        fi
        rm -f "$published_checksum"
    fi
}
abort_release() {
    local status=$1
    rollback_checksum
    trap - EXIT INT TERM
    exit "$status"
}
# END RELEASE_PUBLICATION_HELPERS

trap rollback_checksum EXIT
trap 'abort_release 130' INT
trap 'abort_release 143' TERM
publish_no_clobber "$STAGED_CHECKSUM" "$FINAL_CHECKSUM"
published_checksum="$FINAL_CHECKSUM"
if ! link "$STAGED_DMG" "$FINAL_DMG"; then
    echo "FEHLER: Das fertige DMG konnte nicht veröffentlicht werden." >&2
    exit 5  # der Trap nimmt die Prüfsumme wieder zurück
fi
# Ab dem erfolgreichen Hardlink ist das Paar vollständig. Die Markierung steht
# vor dem Entfernen des Staging-Namens; im winzigen Fenster davor erkennt der
# Signal-Handler dasselbe Paar zusätzlich über `-ef`.
release_pair_complete=1
rm -f "$STAGED_DMG"
published_checksum=""
trap - EXIT INT TERM

echo "RELEASE OK: $PWD/$FINAL_DMG ($VERSION)"

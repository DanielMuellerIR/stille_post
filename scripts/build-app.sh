#!/bin/bash
# Baut die fertige App: kompiliert im Release-Modus und verpackt das Binary in ein
# richtiges .app-Bundle (build/StillePost.app). Das Bundle ist nötig, damit macOS
# der App Mikrofon- und Bedienungshilfen-Rechte dauerhaft zuordnen kann.
#
# Signatur: Liegt eine "Developer ID Application"-Identität im Schlüsselbund, wird
# damit signiert (Hardened Runtime + Timestamp) — WICHTIG, denn nur mit stabiler
# Identität bleiben die einmal erteilten macOS-Berechtigungen über App-Updates
# erhalten. Ohne Identität: Ad-hoc-Signatur (Berechtigungen werden dann nach jedem
# Neubau erneut abgefragt).
#
#   scripts/build-app.sh                # bauen + bestmöglich signieren
#   scripts/build-app.sh --notarize     # zusätzlich bei Apple notarisieren + stapeln
#                                       # (braucht NOTARY_PROFILE, siehe unten)
#   scripts/build-app.sh --install      # danach nach /Applications kopieren —
#                                       # empfohlen: stabiler Ort, macOS-Berechtigungen
#                                       # überleben so auch das Löschen von build/
#   (Flags sind kombinierbar)
#
# Umgebungsvariablen:
#   CODESIGN_IDENTITY  Signatur-Identität erzwingen (Default: automatisch erkannt)
#   NOTARY_PROFILE     Name des notarytool-Keychain-Profils für --notarize
#                      (einmalig anlegen: xcrun notarytool store-credentials <name>
#                       --apple-id <apple-id> --team-id <team-id>)
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        --install) INSTALL=1 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

echo "Kompiliere (Release) …"
swift build -c release

APP="build/StillePost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/StillePost "$APP/Contents/MacOS/StillePost"
cp .build/release/stillepost-cli "$APP/Contents/MacOS/stillepost-cli"

# Eigene Sounds (Start-Blup / Ende-Whoosh) ins Bundle; fehlen sie, nutzt die App
# automatisch macOS-Systemklänge als Ersatz.
if [ -d Resources/sounds ]; then
    mkdir -p "$APP/Contents/Resources/sounds"
    cp Resources/sounds/*.wav "$APP/Contents/Resources/sounds/"
fi

# App-Icon ins Bundle. Das fertige .icns liegt im Repo (erzeugt von
# scripts/build-icon.sh), damit dieser Build kein Zusatzwerkzeug braucht.
# Fehlt es, wird ohne Icon gebaut — macOS zeigt dann den generischen Platzhalter.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "Hinweis: Resources/AppIcon.icns fehlt — Bundle bekommt kein Icon."
fi

# Versionsnummer aus der zentralen VERSION-Datei übernehmen.
VERSION="$(cat VERSION)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Stille Post</string>
    <key>CFBundleDisplayName</key><string>Stille Post</string>
    <key>CFBundleIdentifier</key><string>io.github.danielmuellerir.stillepost</string>
    <key>CFBundleExecutable</key><string>StillePost</string>
    <!-- Verweist auf Contents/Resources/AppIcon.icns (ohne Endung, so will es macOS).
         Fehlt die Datei, fällt macOS still auf den generischen Platzhalter zurück. -->
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menüleisten-App: kein Dock-Symbol, kein App-Switcher-Eintrag. -->
    <key>LSUIElement</key><true/>
    <!-- Begründung für den Mikrofon-Zugriff (zeigt macOS im Berechtigungs-Dialog). -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Stille Post nimmt deine Stimme auf, um sie lokal in Text umzuwandeln. Aufnahmen verlassen den Rechner nicht.</string>
</dict>
</plist>
PLIST

# Signatur-Identität wählen: erzwungene, sonst automatisch erkannte Developer ID,
# sonst Ad-hoc ("-").
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
fi

if [ -n "$IDENTITY" ]; then
    echo "Signiere mit: $IDENTITY"
    # Reihenfolge wichtig: INNERE Binaries zuerst, dann das Bundle — sonst lehnt
    # die Notarisierung ab ("binary is not signed with a valid Developer ID").
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$APP/Contents/MacOS/stillepost-cli"
    # Hardened Runtime + Timestamp (Notarisierungs-Voraussetzungen); das
    # Entitlement erlaubt den Mikrofon-Zugriff unter Hardened Runtime.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/StillePost.entitlements \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict "$APP"
else
    echo "Keine Developer-ID-Identität gefunden — signiere ad-hoc."
    echo "(Hinweis: macOS fragt Berechtigungen dann nach jedem Neubau erneut ab.)"
    codesign --force --sign - "$APP"
fi

if [ "$NOTARIZE" = "1" ]; then
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "FEHLER: --notarize braucht NOTARY_PROFILE (notarytool-Keychain-Profil)." >&2
        exit 1
    fi
    echo "Notarisiere (Profil: $NOTARY_PROFILE) …"
    ditto -c -k --keepParent "$APP" build/StillePost.zip
    xcrun notarytool submit build/StillePost.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/StillePost.zip
    echo "Notarisierung abgeschlossen und angeheftet."
fi

if [ "$INSTALL" = "1" ]; then
    # Laufende Instanz beenden, dann atomar ersetzen (ditto erhält Signatur/Staple).
    pkill -x StillePost 2>/dev/null || true
    rm -rf /Applications/StillePost.app
    ditto "$APP" /Applications/StillePost.app
    echo "Installiert: /Applications/StillePost.app"
    APP="/Applications/StillePost.app"
fi

echo "Fertig: $APP"
echo "Starten:  open $APP"

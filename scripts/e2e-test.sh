#!/bin/bash
# Ende-zu-Ende-Test ohne Mikrofon und ohne GUI:
# 1. erzeugt mit der macOS-Sprachausgabe (`say`) eine deutsche Test-WAV-Datei,
# 2. schickt sie mit stillepost-cli durch die echte Pipeline (Whisper + Bereinigung),
# 3. prüft, dass erwartete Schlüsselwörter im Ergebnis stehen.
#
# Voraussetzungen: whisper-Modell installiert (scripts/install-model.sh),
# Ollama läuft mit dem konfigurierten Bereinigungs-Modell.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Eigene Test-Config: Sprache fest auf Deutsch. Die automatische Sprach-Erkennung
# stolpert über synthetische say-Stimmen (erkennt Englisch und übersetzt!) —
# echte menschliche Sprache ist davon nicht betroffen.
cat > "$TMP/config.json" <<'JSON'
{ "whisper": { "language": "de" } }
JSON
export STILLEPOST_CONFIG="$TMP/config.json"

echo "1/3  Test-Audio erzeugen (say) …"
# Hinweis: Der Satz ist bewusst TTS-tauglich gewählt. Füllwörter wie "ähm" spricht
# die Kunststimme so unnatürlich aus, dass Whisper sie nicht versteht — die
# BEREINIGUNGS-Qualität wird deshalb separat über `stillepost-cli cleanup` geprüft.
TEXT="Hallo, das ist ein Test der Spracherkennung. Bitte alles genau so übernehmen."
# say erzeugt AIFF; afconvert wandelt in unser Pipeline-Format (16 kHz mono WAV).
say -v Anna -o "$TMP/test.aiff" "$TEXT"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/test.aiff" "$TMP/test.wav"

echo "2/3  Pipeline (STT + Bereinigung) …"
swift build >/dev/null
RESULT="$(.build/debug/stillepost-cli transcribe "$TMP/test.wav")"
echo "     Ergebnis: $RESULT"

echo "3/3  Prüfen …"
FAIL=0
# STT-Mechanik: Schlüsselwörter müssen ankommen, nichts darf übersetzt werden.
for WORT in "Spracherkennung" "übernehmen"; do
    if ! grep -qi "$WORT" <<<"$RESULT"; then
        echo "✗ Erwartetes Wort fehlt: $WORT"
        FAIL=1
    fi
done
if grep -qiE "hello|please" <<<"$RESULT"; then
    echo "✗ Whisper hat übersetzt statt transkribiert"
    FAIL=1
fi

# Bereinigungs-Mechanik: Füllwörter + Doppelungen müssen aus ECHTEM Text verschwinden,
# Eigennamen und Wortlaut müssen erhalten bleiben.
CLEAN_IN="also ähm ich wollte halt sagen dass dass der Orkus-Server äh morgen aktualisiert wird"
CLEAN_OUT="$(.build/debug/stillepost-cli cleanup "$CLEAN_IN")"
echo "     Bereinigung: $CLEAN_OUT"
if grep -qiE "ähm|äh |halt " <<<"$CLEAN_OUT "; then
    echo "✗ Füllwörter wurden nicht entfernt"
    FAIL=1
fi
if grep -qi "dass dass" <<<"$CLEAN_OUT"; then
    echo "✗ Wort-Doppelung wurde nicht entfernt"
    FAIL=1
fi
if ! grep -q "Orkus" <<<"$CLEAN_OUT"; then
    echo "✗ Eigenname 'Orkus' wurde verändert (verboten!)"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "✓ Ende-zu-Ende-Test bestanden"
else
    echo "Ende-zu-Ende-Test FEHLGESCHLAGEN"
    exit 1
fi

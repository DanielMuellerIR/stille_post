#!/bin/bash
# Lädt das Whisper-Modell (large-v3-turbo, ~1,6 GB) in den Modell-Ordner der App.
# Quelle: offizielle ggml-Modelle des whisper.cpp-Projekts auf Hugging Face.
#
# Aufruf:  scripts/install-model.sh [modellname] [--force]
#          Default-Modell: large-v3-turbo (beste Mischung aus Qualität und Tempo).
#          --force lädt auch dann, wenn schon eine eigene Kopie liegt.
#
# Exit-Codes: 0 = Modell liegt bereit, 1 = Fehler (siehe Meldung auf stderr).
set -euo pipefail

MODEL="large-v3-turbo"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *)       MODEL="$arg" ;;
    esac
done

DEST_DIR="$HOME/Library/Application Support/StillePost/models"
DEST="$DEST_DIR/ggml-$MODEL.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

# Ist schon eine eigene Kopie da?
#
# Bewusst `-L` VOR `-f` prüfen: `-f` folgt Symlinks und ist deshalb auch dann wahr,
# wenn hier nur ein Verweis auf einen fremden Cache liegt (auf Daniels M3 zeigt der
# Pfad nach ~/.cache/openwhispr/). Genau daran hat das Skript früher immer "Modell
# ist schon da" gemeldet und nie geladen — und Stille Post verliert sein Modell,
# sobald der fremde Cache geräumt wird.
if [ -L "$DEST" ]; then
    echo "Hinweis: $DEST ist nur ein Verweis auf"
    echo "         $(readlink "$DEST")"
    echo "         Räumt das fremde Programm seinen Cache, ist das Modell weg."
    echo "         Lade jetzt eine eigene Kopie und ersetze den Verweis."
elif [ -f "$DEST" ] && [ "$FORCE" -eq 0 ]; then
    echo "Modell ist schon da: $DEST"
    exit 0
fi

mkdir -p "$DEST_DIR"

# Erwartete Größe vorab holen — nur so lässt sich hinterher belegen, dass die Datei
# vollständig ist (eine abgebrochene Wiederaufnahme sieht sonst aus wie Erfolg).
#
# `tail -1` ist wichtig: Hugging Face antwortet erst mit einer 302-Weiterleitung auf
# sein CDN, und deren eigenes `content-length` (~1 kB) steht VOR dem echten. Kein
# `awk IGNORECASE` — das kennt nur GNU-awk, macOS liefert BWK-awk und ignoriert es
# stillschweigend, wodurch genau die 1-kB-Weiterleitung gewinnt.
# `|| true`, damit ein Fehlschlag hier in der eigenen Meldung unten landet und nicht
# im nackten Pipefail-Abbruch.
EXPECTED=$(curl -sIL --fail "$URL" | grep -i '^content-length:' | tail -1 | tr -d '\r' | awk '{print $2}' || true)
EXPECTED="${EXPECTED:-0}"
if [ "$EXPECTED" -lt 1000000 ]; then
    echo "Fehler: Konnte die Größe von $MODEL nicht ermitteln — gibt es das Modell?" >&2
    echo "        $URL" >&2
    exit 1
fi

echo "Lade $MODEL ($((EXPECTED / 1024 / 1024)) MB) von Hugging Face …"
# -L folgt Redirects; --fail bricht bei HTTP-Fehlern ab statt HTML zu speichern;
# -C - setzt einen abgebrochenen Download an der Abbruchstelle fort.
curl -L --fail --progress-bar -C - -o "$DEST.partial" "$URL"

ACTUAL=$(wc -c < "$DEST.partial" | tr -d ' ')
if [ "$ACTUAL" -ne "$EXPECTED" ]; then
    echo "Fehler: $MODEL ist unvollständig ($ACTUAL von $EXPECTED Bytes)." >&2
    echo "        Die Teildatei bleibt liegen — das Skript erneut aufrufen setzt fort:" >&2
    echo "        $DEST.partial" >&2
    exit 1
fi

# `mv` ersetzt einen vorhandenen Symlink, nicht dessen Ziel — der fremde Cache
# bleibt also unangetastet.
mv "$DEST.partial" "$DEST"
echo "Fertig: $DEST"

#!/bin/bash
# Lädt das Whisper-Modell (large-v3-turbo, ~1,6 GB) in den Modell-Ordner der App.
# Quelle: offizielle ggml-Modelle des whisper.cpp-Projekts auf Hugging Face.
#
# Aufruf:  scripts/install-model.sh [modellname]
#          Default-Modell: large-v3-turbo (beste Mischung aus Qualität und Tempo).
set -euo pipefail

MODEL="${1:-large-v3-turbo}"
DEST_DIR="$HOME/Library/Application Support/StillePost/models"
DEST="$DEST_DIR/ggml-$MODEL.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

if [ -f "$DEST" ]; then
    echo "Modell ist schon da: $DEST"
    exit 0
fi

mkdir -p "$DEST_DIR"
echo "Lade $MODEL von Hugging Face (das kann ein paar Minuten dauern) …"
# -L folgt Redirects; --fail bricht bei HTTP-Fehlern ab statt HTML zu speichern.
curl -L --fail --progress-bar -o "$DEST.partial" "$URL"
mv "$DEST.partial" "$DEST"
echo "Fertig: $DEST"

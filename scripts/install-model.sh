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
[[ "$MODEL" =~ ^[[:alnum:]_.-]+$ ]] || { echo "Ungültiger Modellname: $MODEL" >&2; exit 1; }
REVISION=main
SHA256=
case "$MODEL" in
    large-v3-turbo|large-v3)
        REVISION=5359861c739e955e79d9a303bcbc70fb988958b1
        if [ "$MODEL" = large-v3-turbo ]; then
            SHA256=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
        else
            SHA256=64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2
        fi
        ;;
esac
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/$REVISION/ggml-$MODEL.bin"
mkdir -p "$DEST_DIR"

# App und CLI verwenden denselben flock neben dem Ziel. Der Dateideskriptor
# bleibt nach exec im Download-Skript offen, auch während dessen Kindprozessen.
exec /usr/bin/perl -Mstrict -MFcntl=O_CREAT,O_RDWR,O_NOFOLLOW,O_NONBLOCK,LOCK_EX,LOCK_NB -e '
    my ($path, @command) = @ARGV;
    my $lock;
    local $^F = 1024;
    sub fail { print STDERR "Fehler: $_[0]\n"; exit 1; }
    sysopen($lock, $path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0600)
        && -f $lock or fail("Keine reguläre Modellsperre: $path");
    flock($lock, LOCK_EX | LOCK_NB) or fail("Modellinstallation läuft bereits: $path");
    exec @command or fail("Modellinstallation kann nicht gestartet werden: $!");
' "$DEST.lock" /bin/bash -s -- "$MODEL" "$DEST" "$FORCE" "$URL" "$SHA256" <<'INSTALL'
set -euo pipefail
MODEL=$1
DEST=$2
FORCE=$3
URL=$4
SHA256=$5

# Reguläre Dateien und Verweise sind ersetzbar. Ein Verzeichnis oder eine
# Spezialdatei am Modellpfad gehört dem Installer dagegen nicht. Diese Prüfung
# läuft vor dem ersten Netzaufruf, damit ein unbrauchbares Ziel nicht erst nach
# 1,6 GB auffällt.
unsupported_path() {
    local path=$1
    [[ -e "$path" || -L "$path" ]] && [[ ! -f "$path" && ! -L "$path" ]]
}
if unsupported_path "$DEST"; then
    echo "Fehler: Am Modellpfad liegt keine ersetzbare Datei: $DEST" >&2
    exit 1
fi

# Ist schon eine eigene Kopie da?
#
# Bewusst `-L` VOR `-f` prüfen: `-f` folgt Symlinks und ist deshalb auch dann wahr,
# wenn hier nur ein Verweis auf einen fremden Cache liegt. Dessen Lebensdauer
# bestimmt die fremde Anwendung, deshalb wird eine eigene Kopie angelegt.
if [ -L "$DEST" ]; then
    echo "Hinweis: $DEST ist nur ein Verweis auf"
    echo "         $(readlink "$DEST")"
    echo "         Räumt das fremde Programm seinen Cache, ist das Modell weg."
    echo "         Lade jetzt eine eigene Kopie und ersetze den Verweis."
elif [ -f "$DEST" ] && [ "$FORCE" -eq 0 ]; then
    echo "Modell ist schon da: $DEST"
    exit 0
fi

# curl folgt beim Schreiben einem Symlink. Eine Teildatei darf deshalb nur eine
# eigene reguläre Datei sein; sonst könnte eine Wiederaufnahme fremde Daten
# verändern. Verzeichnisse und andere Spezialdateien sind ebenso unbrauchbar.
if [[ -L "$DEST.partial" ]] || unsupported_path "$DEST.partial"; then
    echo "Fehler: Die Teildatei ist keine eigene reguläre Datei: $DEST.partial" >&2
    exit 1
fi

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

# Fortsetzen darf nur, was wirklich der ANFANG der neuen Datei sein kann: eine
# Teildatei, die höchstens so lang ist wie die erwartete. Ist sie länger, wurde das
# Modell am Server durch eine kleinere Fassung ersetzt. `curl -C -` fordert dann
# einen Versatz hinter dem Serverende an und bricht wegen `--fail` ab — und zwar
# bei JEDEM weiteren Versuch, weil die Teildatei liegen bleibt. Genau dieser
# Dauerblocker war in App und CLI schon behoben, im Skript aber nicht.
if [ -f "$DEST.partial" ]; then
    PARTIAL=$(wc -c < "$DEST.partial" | tr -d ' ')
    if [ "$PARTIAL" -gt "$EXPECTED" ]; then
        echo "Hinweis: Angefangene Datei ist größer als $MODEL heute ist — sie kann"
        echo "         nicht dazu gehören und wird verworfen ($PARTIAL statt $EXPECTED Bytes)."
        : > "$DEST.partial"
    fi
fi

echo "Lade $MODEL ($((EXPECTED / 1024 / 1024)) MB) von Hugging Face …"
# -L folgt Redirects; --fail bricht bei HTTP-Fehlern ab statt HTML zu speichern;
# -C - setzt einen abgebrochenen Download an der Abbruchstelle fort.
curl -L --fail --progress-bar --max-filesize "$EXPECTED" -C - -o "$DEST.partial" "$URL"

ACTUAL=$(wc -c < "$DEST.partial" | tr -d ' ')
if [ "$ACTUAL" -ne "$EXPECTED" ]; then
    echo "Fehler: $MODEL ist unvollständig ($ACTUAL von $EXPECTED Bytes)." >&2
    echo "        Die Teildatei bleibt liegen — das Skript erneut aufrufen setzt fort:" >&2
    echo "        $DEST.partial" >&2
    exit 1
fi

# Direkt vor dem Verschieben dieselben Typen erneut prüfen: Während des Downloads
# kann sich der Pfad geändert haben. `mv -h` ist auf macOS zusätzlich nötig, weil
# ein gewöhnliches `mv quelle symlink-auf-ordner` dem Verweis folgt und die Datei
# IN den fremden Ordner legt, statt den Verweis zu ersetzen.
if [[ ! -f "$DEST.partial" || -L "$DEST.partial" ]] || unsupported_path "$DEST"; then
    echo "Fehler: Modell- oder Zielpfad hat sich während des Downloads geändert." >&2
    exit 1
fi
if [ -n "$SHA256" ]; then
    ACTUAL_SHA=$(shasum -a 256 "$DEST.partial" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$SHA256" ]; then
        rm -f -- "$DEST.partial"
        echo "Fehler: Prüfsumme für $MODEL stimmt nicht. Bitte erneut laden." >&2
        exit 1
    fi
fi
mv -f -h "$DEST.partial" "$DEST"
echo "Fertig: $DEST"
INSTALL

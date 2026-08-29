#!/bin/bash
# Regressionstests für die Pfadsicherheit von install-model.sh. Ein nachgebautes
# curl hält den Test vollständig lokal und protokolliert jeden Aufruf.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'CURL'
#!/bin/bash
set -euo pipefail
printf 'aufgerufen\n' >> "$TEST_CURL_MARKER"

for argument in "$@"; do
    if [[ "$argument" == "-sIL" ]]; then
        printf 'HTTP/2 200\r\ncontent-length: 1000001\r\n\r\n'
        exit 0
    fi
done

output=""
previous=""
for argument in "$@"; do
    if [[ "$previous" == "-o" ]]; then
        output="$argument"
        break
    fi
    previous="$argument"
done
[[ -n "$output" ]]
/usr/sbin/mkfile 1000001 "$output"
CURL
chmod +x "$FAKE_BIN/curl"

run_installer() {
    local home=$1
    local log=$2
    set +e
    HOME="$home" PATH="$FAKE_BIN:/usr/bin:/bin" \
        /bin/bash scripts/install-model.sh > "$log" 2>&1
    local status=$?
    set -e
    return "$status"
}

# Ein Verzeichnis ist niemals eine Modelldatei. Der Fehler muss vor HEAD und
# Download sichtbar werden, und vorhandener Inhalt bleibt unangetastet.
directory_home="$TEST_ROOT/directory-home"
directory_target="$directory_home/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin"
mkdir -p "$directory_target"
printf 'wichtig\n' > "$directory_target/nicht-loeschen.txt"
TEST_CURL_MARKER="$TEST_ROOT/directory-curl"
export TEST_CURL_MARKER
if run_installer "$directory_home" "$TEST_ROOT/directory.log"; then
    echo "FEHLER: Verzeichnis am Modellpfad wurde als Ziel akzeptiert" >&2
    exit 1
fi
[[ ! -e "$TEST_CURL_MARKER" ]]
grep -Fq 'wichtig' "$directory_target/nicht-loeschen.txt"

# `mv quelle symlink-auf-ordner` folgt unter macOS dem Verweis. Das Skript muss
# ihn deshalb ausdrücklich als Verweis behandeln und am Ziel ersetzen.
symlink_home="$TEST_ROOT/symlink-home"
symlink_models="$symlink_home/Library/Application Support/StillePost/models"
foreign_directory="$TEST_ROOT/fremder-ordner"
mkdir -p "$symlink_models" "$foreign_directory"
symlink_target="$symlink_models/ggml-large-v3-turbo.bin"
ln -s "$foreign_directory" "$symlink_target"
TEST_CURL_MARKER="$TEST_ROOT/symlink-curl"
export TEST_CURL_MARKER
run_installer "$symlink_home" "$TEST_ROOT/symlink.log"
[[ -f "$symlink_target" && ! -L "$symlink_target" ]]
[[ $(wc -c < "$symlink_target" | tr -d ' ') -eq 1000001 ]]
[[ -z "$(find "$foreign_directory" -mindepth 1 -print -quit)" ]]

# Auch die Teildatei darf kein Verweis sein: curl würde beim Fortsetzen sonst
# eine fremde Datei verändern. Wieder muss der Abbruch vor jedem Netzaufruf kommen.
partial_home="$TEST_ROOT/partial-home"
partial_models="$partial_home/Library/Application Support/StillePost/models"
mkdir -p "$partial_models"
partial_target="$partial_models/ggml-large-v3-turbo.bin.partial"
foreign_file="$TEST_ROOT/fremde-datei"
printf 'nicht veraendern\n' > "$foreign_file"
ln -s "$foreign_file" "$partial_target"
TEST_CURL_MARKER="$TEST_ROOT/partial-curl"
export TEST_CURL_MARKER
if run_installer "$partial_home" "$TEST_ROOT/partial.log"; then
    echo "FEHLER: Verweis als Teildatei wurde akzeptiert" >&2
    exit 1
fi
[[ ! -e "$TEST_CURL_MARKER" ]]
grep -Fxq 'nicht veraendern' "$foreign_file"

echo "✓ Modellinstallation verändert nur reguläre Ziel- und Teildateien"

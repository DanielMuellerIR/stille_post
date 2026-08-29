#!/bin/bash
# Prüft CLI-Argumente und Diagnose-Exit-Codes ohne persönliche Konfiguration,
# Schlüsselbund, Verlauf oder Netz zu berühren.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
CONFIG="$TEST_ROOT/config.json"
cat > "$CONFIG" <<'JSON'
{
  "whisper": {
    "serverURL": "http://127.0.0.1:9",
    "autostart": false,
    "binaryPath": "/var/empty/stillepost-cli-test/whisper-server",
    "modelPath": "/var/empty/stillepost-cli-test/model.bin",
    "language": "de"
  },
  "cleanup": {
    "enabled": false
  }
}
JSON

run_cli() {
    STILLEPOST_LANGUAGE=de \
    STILLEPOST_CONFIG="$CONFIG" \
    STILLEPOST_APP_SUPPORT="$TEST_ROOT/app-support" \
        .build/debug/stillepost-cli "$@"
}

expect_usage_error() {
    local output status
    set +e
    output=$(run_cli "$@" 2>&1)
    status=$?
    set -e
    if [[ "$status" -ne 2 ]] || ! grep -Fq 'Verwendung:' <<<"$output"; then
        echo "FEHLER: Ungültiger Aufruf wurde nicht mit Verwendung und Exit 2 abgewiesen: $*" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

# Ohne Selbststart sind fehlendes Binary und Modell keine zusätzlichen aktiven
# Probleme. Der nicht laufende Server ist der eine vollständige Befund.
set +e
doctor_output=$(run_cli doctor 2>&1)
doctor_status=$?
set -e
[[ "$doctor_status" -eq 1 ]]
grep -Fq '1 Problem gefunden.' <<<"$doctor_output"
if grep -Fq 'whisper-server-Binary fehlt' <<<"$doctor_output"; then
    echo "FEHLER: doctor prüft unbenutzte Selbststart-Dateien trotz autostart=false" >&2
    exit 1
fi

# Jeder dieser Aufrufe muss VOR Netz, Schlüsselbund, Verlauf oder Serverstart
# abbrechen. Zusätzliche Argumente werden nicht still ignoriert.
expect_usage_error doctor --unbekannt
expect_usage_error install-model --focre
expect_usage_error transcribe /var/empty/nicht-vorhanden.wav --rwa
expect_usage_error cleanup text zusaetzlich
expect_usage_error bridge status --unbekannt
expect_usage_error bridge token --revel
expect_usage_error bridge serve --unbekannt
expect_usage_error history list --jsoon
expect_usage_error history clear --unbekannt
expect_usage_error set-cleanup-key --unbekannt

# Gültige Formen behalten ihren Vertrag. Die isolierte Konfiguration schaltet die
# Bereinigung aus; deshalb bleibt der Text lokal und wortgleich.
cleanup_output=$(run_cli cleanup 'Hallo CLI' 2> "$TEST_ROOT/cleanup.stderr")
[[ "$cleanup_output" == "Hallo CLI" ]]
history_json=$(run_cli history list --json)
[[ "$(tr -d '[:space:]' <<<"$history_json")" == "[]" ]]

echo "✓ CLI weist unbekannte Argumente vor jeder Nebenwirkung ab"

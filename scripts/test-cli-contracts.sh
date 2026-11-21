#!/bin/bash
# Prüft CLI-Verträge mit isolierter Konfiguration und ohne Schlüsselbundzugriff.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product stillepost-cli >/dev/null

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

# Ein TTY-Fehler darf nicht auf sichtbare Eingabe zurückfallen. Der Testhaken
# simuliert genau den Fehlerstatus und muss VOR `readLine` mit Exit 1 enden.
set +e
echo_failure_output=$(printf 'darf-nie-gelesen-werden\n' \
    | STILLEPOST_TEST_TERMINAL_ECHO_FAILURE=1 run_cli set-cleanup-key 2>&1)
echo_failure_status=$?
set -e
[[ "$echo_failure_status" -eq 1 ]]
grep -Fq 'Terminal-Anzeige konnte nicht sicher abgeschaltet werden' \
    <<<"$echo_failure_output"

STILLEPOST_LANGUAGE=de STILLEPOST_CONFIG="$CONFIG" STILLEPOST_APP_SUPPORT="$TEST_ROOT/app-support" \
    /usr/bin/python3 - .build/debug/stillepost-cli <<'PYTHON'
import os
import pty
import signal
import subprocess
import sys
import termios
import time

cli = sys.argv[1]
byte_limit = 1_048_576

def cleanup(payload):
    return subprocess.run([cli, 'cleanup', '-'], input=payload, capture_output=True, timeout=10)

valid = cleanup('Grüße aus der Pipe'.encode())
assert valid.returncode == 0 and valid.stdout == 'Grüße aus der Pipe\n'.encode()
at_limit = cleanup(b'a' * byte_limit)
assert at_limit.returncode == 0 and len(at_limit.stdout) == byte_limit + 1
for payload, message in [(b'\xff', 'ungültiges UTF-8'), (b'a' * (byte_limit + 1), 'überschreitet die Grenze')]:
    result = cleanup(payload)
    assert result.returncode == 2 and not result.stdout and message.encode() in result.stderr

for interrupt in [signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, None]:
    master, terminal = pty.openpty()
    try:
        original = termios.tcgetattr(terminal)
        assert original[3] & termios.ECHO
        with subprocess.Popen([cli, 'set-cleanup-key'], stdin=terminal, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as child:
            try:
                deadline = time.monotonic() + 5
                while termios.tcgetattr(terminal)[3] & termios.ECHO:
                    assert child.poll() is None and time.monotonic() < deadline
                    time.sleep(.005)
                if interrupt is None:
                    os.write(master, bytes(original[6][termios.VEOF]))
                else:
                    child.send_signal(interrupt)
                output, _ = child.communicate(timeout=5)
                assert child.returncode == (2 if interrupt is None else -interrupt)
                assert not output
                assert termios.tcgetattr(terminal) == original
            finally:
                if child.poll() is None:
                    child.kill()
    finally:
        os.close(master)
        os.close(terminal)
PYTHON

echo "✓ CLI-Aufrufe, Standardeingabe und Terminalzustand geprüft"

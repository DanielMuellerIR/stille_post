#!/bin/bash
# Prüft den echten Bundle-Bau in einer lokalen Fixture ohne Swift-Compiler oder
# Schlüsselbundzugriff. Die Signaturaufrufe belegen nur den gewählten Baupfad.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
FIXTURE="$TEST_ROOT/project"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FIXTURE/scripts" "$FAKE_BIN"
cp scripts/build-app.sh "$FIXTURE/scripts/"
cp VERSION THIRD-PARTY.md "$FIXTURE/"
mkdir -p "$FIXTURE/Sources/StillePostCore"
cp -R Sources/StillePostCore/Resources "$FIXTURE/Sources/StillePostCore/"
mkdir -p "$FIXTURE/Resources"
cp Resources/StillePost.entitlements "$FIXTURE/Resources/"

TEST_SWIFT_OUTPUT="$FIXTURE/.build/fixture/release"
export TEST_SWIFT_OUTPUT
mkdir -p "$TEST_SWIFT_OUTPUT/StillePost_StillePostCore.bundle"
printf 'fixture\n' > "$TEST_SWIFT_OUTPUT/StillePost"
cp "$TEST_SWIFT_OUTPUT/StillePost" "$TEST_SWIFT_OUTPUT/stillepost-cli"
printf 'aktuelle Ressourcen\n' > "$TEST_SWIFT_OUTPUT/StillePost_StillePostCore.bundle/marker"
SPARKLE="$FIXTURE/.build/artifacts/sparkle/Sparkle.framework/Versions/B"
mkdir -p "$SPARKLE/Updater.app"
touch "$SPARKLE/Autoupdate"

cat > "$FAKE_BIN/swift" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "${*: -1}" == "--show-bin-path" ]]; then
    printf '%s\n' "$TEST_SWIFT_OUTPUT"
fi
SH
cat > "$FAKE_BIN/security" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'lookup\n' >> "$TEST_SECURITY_LOG"
case "$TEST_SECURITY_MODE" in
    none) printf '0 valid identities found\n' ;;
    other) printf '1) ABC "Apple Development: Fixture Company"\n1 valid identities found\n' ;;
    developer)
        printf '1) ABC "Developer ID Application: Fixture Company (TEST000000)"\n'
        printf '2) DEF "Developer ID Application: Other Company (TEST000001)"\n'
        printf '2 valid identities found\n' ;;
    error) exit 1 ;;
esac
SH
cat > "$FAKE_BIN/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CODESIGN_LOG"
SH
chmod +x "$FAKE_BIN/swift" "$FAKE_BIN/security" "$FAKE_BIN/codesign"
export TEST_SECURITY_MODE TEST_SECURITY_LOG TEST_CODESIGN_LOG

run_build() {
    local scenario=$1
    local identity=${2:-}
    TEST_SECURITY_MODE=$scenario
    TEST_SECURITY_LOG="$TEST_ROOT/$scenario-security.log"
    TEST_CODESIGN_LOG="$TEST_ROOT/$scenario-codesign.log"
    (
        cd "$FIXTURE"
        CODESIGN_IDENTITY="$identity" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
            /bin/bash scripts/build-app.sh
    ) > "$TEST_ROOT/$scenario-build.log" 2>&1
}

for scenario in none other; do
    if ! run_build "$scenario"; then
        cat "$TEST_ROOT/$scenario-build.log" >&2
        echo "FEHLER: Bau ohne Developer-ID erreicht keine Ad-hoc-Signatur" >&2
        exit 1
    fi
    grep -Fq -- '--force --sign - ' "$TEST_CODESIGN_LOG"
    [[ $(wc -l < "$TEST_CODESIGN_LOG") -eq 1 ]]
    grep -Fxq 'aktuelle Ressourcen' "$FIXTURE/build/StillePost.app/Contents/Resources/StillePost_StillePostCore.bundle/marker"
done

run_build developer
grep -Fq -- '--sign Developer ID Application: Fixture Company (TEST000000)' "$TEST_CODESIGN_LOG"
if grep -Fq 'Other Company' "$TEST_CODESIGN_LOG"; then
    echo "FEHLER: Automatische Suche verwendet mehr als die erste Developer-ID" >&2
    exit 1
fi
[[ $(wc -l < "$TEST_CODESIGN_LOG") -eq 6 ]]
grep -Fq -- '--verify --deep --strict' "$TEST_CODESIGN_LOG"

run_build explicit 'Developer ID Application: Explicit Company (TEST000002)'
[[ ! -e "$TEST_SECURITY_LOG" ]]
grep -Fq -- '--sign Developer ID Application: Explicit Company (TEST000002)' "$TEST_CODESIGN_LOG"

# Ein echter Fehler der Identitätssuche darf nicht als „kein Zertifikat“ gelten.
if run_build error; then
    echo "FEHLER: Fehlgeschlagene Identitätssuche wurde übergangen" >&2
    exit 1
fi
[[ ! -e "$TEST_CODESIGN_LOG" ]]
echo "✓ Ad-hoc, automatische und explizite Developer-ID sowie Suchfehler geprüft"

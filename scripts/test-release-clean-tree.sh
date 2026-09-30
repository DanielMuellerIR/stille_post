#!/bin/bash
# Prüft den echten Release-Einstieg in isolierten Git-Repos, ohne Apple-Aufrufe.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
FIXTURE="$TEST_ROOT/repo"
mkdir -p "$FIXTURE/scripts"
cp release.sh "$FIXTURE/release.sh"
printf 'test\n' > "$FIXTURE/VERSION"
printf 'build/\n' > "$FIXTURE/.gitignore"
# Dieser Ersatz beweist, ob der Release-Einstieg den Build erreicht. Er endet
# absichtlich dort, bevor Signatur, Notarisierung oder Veröffentlichung beginnen.
cat > "$FIXTURE/scripts/build-app.sh" <<'BUILD'
#!/bin/bash
touch build-was-called
exit 42
BUILD
chmod +x "$FIXTURE/scripts/build-app.sh"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" add release.sh VERSION .gitignore scripts/build-app.sh
git -C "$FIXTURE" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture

run_release() {
    set +e
    output=$(cd "$FIXTURE" && NOTARY_PROFILE=test DEVELOPER_TEAM_ID=test bash release.sh 2>&1)
    status=$?
    set -e
}
expect_dirty_rejection() {
    run_release
    if [[ "$status" -ne 7 ]] || [[ -e "$FIXTURE/build-was-called" ]] \
       || ! grep -Fq 'sauberen Git-Arbeitsbaum' <<<"$output"; then
        echo "FEHLER: Unsauberer Arbeitsbaum erreichte den Release-Build." >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

# Ungestagte, gestagte und neue Dateien müssen jeweils vor dem Build abbrechen.
printf 'changed\n' >> "$FIXTURE/VERSION"
expect_dirty_rejection
git -C "$FIXTURE" add VERSION
expect_dirty_rejection
git -C "$FIXTURE" -c user.name=Test -c user.email=test@example.invalid commit -qm saved
printf 'new\n' > "$FIXTURE/new-file"
expect_dirty_rejection
rm "$FIXTURE/new-file"

# Ein sauberer Quellstand mit ignorierten Build-Dateien erreicht dagegen den
# Build. So sperrt das Gate den normalen zweiten Release-Versuch nicht aus.
mkdir -p "$FIXTURE/build"
printf 'ignored\n' > "$FIXTURE/build/existing-file"
run_release
if [[ "$status" -ne 42 ]] || [[ ! -f "$FIXTURE/build-was-called" ]]; then
    echo "FEHLER: Sauberer Arbeitsbaum erreichte den Release-Build nicht." >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
[[ ! -d "$FIXTURE/build/.release-lock" ]]
echo "✓ Release lehnt ungestagte, gestagte und neue Dateien vor dem Build ab"
echo "✓ Ignorierte Build-Artefakte erlauben den Release-Einstieg"

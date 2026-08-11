#!/bin/bash
# Regressionstest für den Signal-/Rollback-Vertrag in release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
HELPERS="$TEST_ROOT/helpers.sh"
awk '
  /# BEGIN RELEASE_PUBLICATION_HELPERS/ { capture=1; next }
  /# END RELEASE_PUBLICATION_HELPERS/ { capture=0 }
  capture { print }
' release.sh > "$HELPERS"
bash -n "$HELPERS"
# shellcheck source=/dev/null
source "$HELPERS"

STAGED_DMG="$TEST_ROOT/staged.dmg"
FINAL_DMG="$TEST_ROOT/final.dmg"
FINAL_CHECKSUM="$TEST_ROOT/final.dmg.sha256"
printf 'dmg\n' > "$STAGED_DMG"
printf 'sum\n' > "$FINAL_CHECKSUM"
published_checksum="$FINAL_CHECKSUM"
release_pair_complete=0

set +e
( abort_release 130 )
status=$?
set -e
[[ "$status" -eq 130 ]]
[[ ! -e "$FINAL_CHECKSUM" ]]

# Nach erfolgreichem Hardlink ist das Paar vollständig, auch wenn das Signal
# vor der Shell-Markierung ankommt. Die Prüfsumme muss dann erhalten bleiben.
printf 'sum\n' > "$FINAL_CHECKSUM"
link "$STAGED_DMG" "$FINAL_DMG"
published_checksum="$FINAL_CHECKSUM"
release_pair_complete=0
set +e
( abort_release 143 )
status=$?
set -e
[[ "$status" -eq 143 ]]
[[ -f "$FINAL_CHECKSUM" ]]

grep -Fq "trap 'abort_release 130' INT" release.sh
grep -Fq "trap 'abort_release 143' TERM" release.sh
echo "✓ Release-Signale enden mit Fehler und hinterlassen nie ein halbes eigenes Paar"

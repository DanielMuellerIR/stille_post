#!/bin/bash
# Regressionstest für den Signal-/Rollback-Vertrag und die Laufsperre in release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
# Beide Helferblöcke aus release.sh holen und hier ausführen: So wird genau der
# Code geprüft, der im echten Lauf steht — nicht eine Nachbildung davon.
extract_block() {
    awk -v begin="# BEGIN $1" -v end="# END $1" '
      $0 ~ begin { capture=1; next }
      $0 ~ end { capture=0 }
      capture { print }
    ' release.sh
}

LOCK_HELPERS="$TEST_ROOT/lock-helpers.sh"
extract_block RELEASE_LOCK_HELPERS > "$LOCK_HELPERS"
bash -n "$LOCK_HELPERS"
# shellcheck source=/dev/null
source "$LOCK_HELPERS"

HELPERS="$TEST_ROOT/helpers.sh"
extract_block RELEASE_PUBLICATION_HELPERS > "$HELPERS"
bash -n "$HELPERS"
# shellcheck source=/dev/null
source "$HELPERS"

# --- Laufsperre: zwei gleichzeitige Release-Läufe schließen sich aus ----------
LOCK="$TEST_ROOT/release-lock"
acquire_release_lock "$LOCK"
[[ -d "$LOCK" ]]
if ( acquire_release_lock "$LOCK" ); then
    echo "FEHLER: zweiter Release-Lauf bekam dieselbe Sperre" >&2
    exit 1
fi
release_lock
if [[ -e "$LOCK" ]]; then
    echo "FEHLER: Sperre wurde nach dem Lauf nicht freigegeben" >&2
    exit 1
fi
# Nach der Freigabe darf der nächste Lauf wieder ran.
acquire_release_lock "$LOCK"
release_lock
echo "✓ Release-Läufe serialisieren sich über die Sperre in build/"

STAGED_DMG="$TEST_ROOT/staged.dmg"
FINAL_DMG="$TEST_ROOT/final.dmg"
STAGED_CHECKSUM="$TEST_ROOT/staged.dmg.sha256"
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

# Abbruch exakt nach dem Prüfsummen-Hardlink: Der Shell-Marker ist noch leer,
# aber die gemeinsame Inode-Identität mit dem Staging-Namen beweist Eigentum.
# Der Rollback muss die einzelne finale Prüfsumme deshalb entfernen.
printf 'sum\n' > "$STAGED_CHECKSUM"
link "$STAGED_CHECKSUM" "$FINAL_CHECKSUM"
[[ -e "$FINAL_CHECKSUM" ]]
published_checksum=""
release_pair_complete=0
rollback_checksum
if [[ -e "$FINAL_CHECKSUM" ]]; then
    echo "FEHLER: einzelne finale Prüfsumme wurde nach Abbruch nicht entfernt" >&2
    exit 1
fi
rm -f "$STAGED_CHECKSUM"

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
# In beiden Abschlusswegen muss die idempotente Freigabe VOR dem Entfernen der
# Signal-Handler stehen. Sonst kann ein Signal im Zwischenraum die Sperre erben.
awk '
  /abort_release\(\)/ { in_abort=1; saw_release=0 }
  in_abort && /release_lock/ { saw_release=1 }
  in_abort && /trap - EXIT INT TERM/ {
    if (!saw_release) exit 1
    checked_abort=1
    in_abort=0
  }
  /^release_pair_complete=1$/ { in_success=1; saw_success_release=0 }
  in_success && /release_lock/ { saw_success_release=1 }
  in_success && /trap - EXIT INT TERM/ {
    if (!saw_success_release) exit 1
    checked_success=1
    in_success=0
  }
  END { if (!checked_abort || !checked_success) exit 1 }
' release.sh
echo "✓ Release-Signale enden mit Fehler und hinterlassen nie ein halbes eigenes Paar"

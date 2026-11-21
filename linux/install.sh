#!/bin/sh
# Benutzerlokale Installation; Config, Verlauf und Modelle bleiben separat.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(cat "$source_dir/VERSION")
install_root="${XDG_DATA_HOME:-$HOME/.local/share}/stillepost/app"
if ! result=$(python3 "$source_dir/update.py" install-local); then
    printf '%s\n' "$result" >&2
    exit 1
fi
resumed=$(printf '%s\n' "$result" | python3 -c 'import json, sys; print(int(json.load(sys.stdin).get("resumed", False)))')
installed_dir="$install_root/$version"
bin_dir="$HOME/.local/bin"
desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$bin_dir" "$desktop_dir"
launcher_tmp=$(mktemp "$bin_dir/.stillepost.XXXXXXXX")
desktop_tmp=""
trap 'rm -f -- "$launcher_tmp" "$desktop_tmp"' EXIT
trap 'exit 1' HUP INT TERM
desktop_tmp=$(mktemp "$desktop_dir/.stillepost.XXXXXXXX")
# Der Launcher bleibt auch bei einem späteren Versionswechsel unverändert.
cat > "$launcher_tmp" <<EOF
#!/bin/sh
exec python3 "$install_root/current/launcher.py" "\$@"
EOF
chmod 755 "$launcher_tmp"
sed -e "s|^Exec=.*|Exec=\"$bin_dir/stillepost\"|" -e "s|^Icon=.*|Icon=$install_root/current/icon.png|" "$installed_dir/stillepost.desktop" > "$desktop_tmp"
chmod 644 "$desktop_tmp"
mv -fT "$launcher_tmp" "$bin_dir/stillepost"
mv -fT "$desktop_tmp" "$desktop_dir/io.github.danielmuellerir.stillepost.desktop"
if [ "${STILLEPOST_SKIP_MODEL_SETUP:-0}" != 1 ]; then
    python3 "$installed_dir/setup-models.py"
fi
if [ "$resumed" = 1 ]; then
    echo "Vorhandene Installation von Stille Post $version vervollständigt. Start: $bin_dir/stillepost"
else
    echo "Stille Post $version installiert. Start: $bin_dir/stillepost"
fi

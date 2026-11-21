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
mkdir -p "$HOME/.local/bin" "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
# Der Launcher bleibt auch bei einem späteren Versionswechsel unverändert.
cat > "$HOME/.local/bin/stillepost" <<EOF
#!/bin/sh
exec python3 "$install_root/current/launcher.py" "\$@"
EOF
chmod 755 "$HOME/.local/bin/stillepost"
sed -e "s|^Exec=.*|Exec=\"$HOME/.local/bin/stillepost\"|" -e "s|^Icon=.*|Icon=$install_root/current/icon.png|" "$source_dir/stillepost.desktop" > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/io.github.danielmuellerir.stillepost.desktop"
if [ "${STILLEPOST_SKIP_MODEL_SETUP:-0}" != 1 ]; then
    python3 "$install_root/$version/setup-models.py"
fi
echo "Stille Post $version installiert. Start: $HOME/.local/bin/stillepost"

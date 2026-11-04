#!/bin/sh
# Benutzerlokale Installation; Config, Verlauf und Modelle bleiben separat.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(cat "$source_dir/VERSION")
case "$version" in *[!0-9.]*|'') echo 'Ungültige Version' >&2; exit 1;; esac
install_root="${XDG_DATA_HOME:-$HOME/.local/share}/stillepost/app"
mkdir -p "$install_root" "$HOME/.local/bin" "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if [ -e "$install_root/$version" ]; then
    echo 'Diese Version ist bereits installiert.' >&2
    exit 1
fi
stage=$(mktemp -d "$install_root/.install.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
cp -a "$source_dir/." "$stage/"
LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$stage/bin/stillepost-linux" --version >/dev/null
mv "$stage" "$install_root/$version"
if [ -L "$install_root/current" ]; then
    readlink "$install_root/current" > "$install_root/previous-version"
fi
ln -s "$version" "$install_root/.current.$$"
mv -Tf "$install_root/.current.$$" "$install_root/current"
# Der Launcher bleibt auch bei einem späteren Versionswechsel unverändert.
cat > "$HOME/.local/bin/stillepost" <<EOF
#!/bin/sh
exec python3 "$install_root/current/launcher.py" "\$@"
EOF
chmod 755 "$HOME/.local/bin/stillepost"
sed -e "s|^Exec=.*|Exec=\"$HOME/.local/bin/stillepost\"|" -e "s|^Icon=.*|Icon=$install_root/current/icon.png|" "$source_dir/stillepost.desktop" > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/io.github.danielmuellerir.stillepost.desktop"
if [ "${STILLEPOST_SKIP_MODEL_SETUP:-0}" != 1 ]; then
    python3 "$install_root/current/setup-models.py"
fi
echo "Stille Post $version installiert. Start: $HOME/.local/bin/stillepost"

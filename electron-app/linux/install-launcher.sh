#!/bin/sh
# Installs a "Pip" launcher into your app menu (run-from-source setups).
# Creates ~/.local/share/applications/pip-mascot.desktop pointing at this checkout.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"        # electron-app/linux
APPDIR="$(cd "$HERE/.." && pwd)"             # electron-app
REPO="$(cd "$APPDIR/.." && pwd)"             # repo root

LAUNCH="$HERE/pip-launch.sh"
ICON="$REPO/mascot/front.png"
[ -f "$ICON" ] || ICON="$APPDIR/assets/idle-right.png"

chmod +x "$LAUNCH"

DEST="$HOME/.local/share/applications"
mkdir -p "$DEST"
sed -e "s|@@LAUNCH@@|$LAUNCH|g" -e "s|@@ICON@@|$ICON|g" \
  "$HERE/pip-mascot.desktop" > "$DEST/pip-mascot.desktop"
chmod +x "$DEST/pip-mascot.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DEST" >/dev/null 2>&1 || true
fi

echo "Installed Pip launcher → $DEST/pip-mascot.desktop"
echo "Search for 'Pip' in your applications menu to launch it."

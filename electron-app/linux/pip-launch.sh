#!/bin/sh
# Launches the Pip mascot from a source checkout. Used by the .desktop entry that
# install-launcher.sh sets up, but you can also run it directly.

# If set, Electron runs as a plain Node process instead of opening the GUI. Some
# environments (e.g. an editor's integrated terminal) export this; clear it so the
# launcher always starts the actual app.
unset ELECTRON_RUN_AS_NODE

APPDIR="$(cd "$(dirname "$0")/.." && pwd)"   # electron-app/
cd "$APPDIR" || exit 1

if [ -x ./node_modules/electron/dist/electron ]; then
  exec ./node_modules/electron/dist/electron .
elif command -v npx >/dev/null 2>&1; then
  exec npx electron .
else
  echo "Electron isn't installed. Run 'npm install' in $APPDIR first." >&2
  exit 1
fi

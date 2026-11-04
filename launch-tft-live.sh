#!/bin/zsh
DIR="${0:A:h}"
umask 077
DATA_DIR="${TFT_LIVE_DATA_DIR:-$HOME/Library/Application Support/TFT Live}"
mkdir -p "$DATA_DIR"
PYTHON="$DIR/TFT Live.app/Contents/Resources/python/bin/python3"
if [[ -x "$PYTHON" ]]; then
  exec "$PYTHON" -I -B "$DIR/launch_windows_live.py" >>"$DATA_DIR/launcher.log" 2>&1
fi
exec /usr/bin/arch -arm64 /usr/bin/python3 -I "$DIR/launch_windows_live.py" >>"$DATA_DIR/launcher.log" 2>&1

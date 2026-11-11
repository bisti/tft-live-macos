#!/bin/zsh
DIR="${0:A:h}"
umask 077
DATA_DIR="${TFT_LIVE_DATA_DIR:-$HOME/Library/Application Support/TFT Live}"
mkdir -p "$DATA_DIR"
PYTHON="$DIR/TFT Live.app/Contents/Resources/python/bin/python3"
if [[ -x "$PYTHON" ]]; then
  "$PYTHON" -I -B -c 'import pathlib, sys; sys.path.insert(0, sys.argv[1]); import launcher_config; launcher_config.rotate_log(pathlib.Path(sys.argv[2]))' "$DIR" "$DATA_DIR/launcher.log" || exit 1
  exec "$PYTHON" -I -B -u "$DIR/launch_windows_live.py" >>"$DATA_DIR/launcher.log" 2>&1
fi
/usr/bin/arch -arm64 /usr/bin/python3 -I -B -c 'import pathlib, sys; sys.path.insert(0, sys.argv[1]); import launcher_config; launcher_config.rotate_log(pathlib.Path(sys.argv[2]))' "$DIR" "$DATA_DIR/launcher.log" || exit 1
exec /usr/bin/arch -arm64 /usr/bin/python3 -I "$DIR/launch_windows_live.py" >>"$DATA_DIR/launcher.log" 2>&1

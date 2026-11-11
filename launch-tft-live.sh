#!/bin/zsh
set -eu
cd "${0:A:h}"
umask 077
if [[ -x 'TFT Live.app/Contents/MacOS/TFTLiveCLI' ]]; then
  exec './TFT Live.app/Contents/MacOS/TFTLiveCLI' --log-output "$@"
fi
if [[ -x '.build/arm64-apple-macosx/release/TFTLiveCLI' ]]; then
  exec '.build/arm64-apple-macosx/release/TFTLiveCLI' --log-output "$@"
fi
echo 'Build the native launcher with ./build.sh, then run it again.' >&2
exit 1

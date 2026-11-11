#!/bin/zsh
set -eu
cd "${0:A:h}"
DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
FRAMEWORKS="$DEVELOPER_PATH/Library/Frameworks"
if [[ -d "$DEVELOPER_PATH/Library/Developer/Frameworks/Testing.framework" ]]; then
  FRAMEWORKS="$DEVELOPER_PATH/Library/Developer/Frameworks"
fi
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  EXTRA_LINK=()
  if [[ -f "${FRAMEWORKS:h}/usr/lib/lib_TestingInterop.dylib" ]]; then
    EXTRA_LINK=(-Xlinker -rpath -Xlinker "${FRAMEWORKS:h}/usr/lib")
  fi
  exec swift test --arch arm64 --disable-xctest -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "${EXTRA_LINK[@]}" "$@"
fi
exec swift test --arch arm64 --disable-xctest "$@"

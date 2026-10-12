#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Hook readiness fixtures require macOS Foundation." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${THEOS:?THEOS must identify the build checkout for its Substrate headers}"
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-hook-test.XXXXXX")
trap 'rm -f "$BUILD/test-hook-readiness"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
    -I"$THEOS/vendor/include" -F"$THEOS/vendor/lib" \
    -I"$ROOT/shared" -I"$ROOT/tweak/Common" -I"$ROOT/tweak/Container" -I"$ROOT/tweak/Identity" \
    -framework Foundation "$ROOT/tools/test_hook_readiness.mm" -o "$BUILD/test-hook-readiness"
"$BUILD/test-hook-readiness"

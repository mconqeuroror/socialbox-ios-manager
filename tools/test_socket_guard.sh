#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo "Socket guard fixtures require Darwin sockets and macOS Foundation." >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${THEOS:?THEOS must identify the build checkout for its Substrate headers}"
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/redditbox-socket-test.XXXXXX")
trap 'rm -f "$BUILD/test-socket-guard" "$BUILD/http-proxy.o"; rmdir "$BUILD"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -c "$ROOT/shared/RBXHTTPProxy.m" -o "$BUILD/http-proxy.o"
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
    -I"$THEOS/vendor/include" -F"$THEOS/vendor/lib" \
    -I"$ROOT/shared" -I"$ROOT/tweak/Common" -I"$ROOT/tweak/Container" -I"$ROOT/tweak/Network" \
    -framework Foundation -framework CFNetwork "$ROOT/tools/test_socket_guard.mm" "$BUILD/http-proxy.o" \
    -o "$BUILD/test-socket-guard"
"$BUILD/test-socket-guard"
